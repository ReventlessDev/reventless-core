module type T = {
  module Spec: Reventless.StateChangeSlice.Spec
  let handleCommands: (
    DcbEventLog.operations,
    Stream.t<
      CommandTopic.topicItem<Message.command'<Reventless.Id.String.t, Spec.command>>,
      string,
      unit,
    >,
  ) => Effect.t<array<result<string, string>>, string, unit>
}

module Make = (Spec: Reventless.StateChangeSlice.Spec): (T with module Spec = Spec) => {
  module Spec = Spec

  let comp = `StateChangeSlice(${Spec.name})`

  let decoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)
  let queryEventTypes = decoder.eventTypes

  let encodeEvent = (event: Spec.event): ReventlessInfra.DcbEventLog.rawEvent => {
    let json = event->JSON.stringifyAny->Option.getOrThrow->JSON.parseOrThrow
    let (eventType, data) = json->Message.splitMessage
    let tags =
      Reventless.DcbTag.extractTags(Spec.eventSchema, event)
      ->Array.concat([{Reventless.DcbTag.key: "originatorSlice", value: Spec.name}])
    {eventType, data: JSON.Object(data), tags}
  }

  // Computed once at functor init — used to extract entityId for publishJsonsAndWait outcomes.
  let derivedPartitionTag = Reventless.DcbTag.derivePartitionTag([
    (Spec.name, Spec.moduleUrl, Spec.eventSchema->S.castToUnknown),
  ])

  let maxRetries = 3

  // Processes one command against the DCB event log with optimistic concurrency:
  //   1. Reads relevant events (filtered by command tags) to build the decision model
  //   2. Decodes raw events using consumedEventSchema
  //   3. Calls Spec.decide to produce new events
  //   4. Encodes produced events to raw and appends with a condition
  //   5. On conflict, retries from step 1 (up to maxRetries)
  let handleSingleCommand = (
    dcbEventLog: DcbEventLog.operations,
    command': Message.command'<Reventless.Id.String.t, Spec.command>,
  ) => {
    let cmdJson =
      command'->Message.commandJsonOfCommand'(
        ~idToString=Reventless.Id.String.toString,
        ~commandSchema=Spec.commandSchema,
      )
    EffectLogger.logInfo(
      ~comp,
      ~detail=cmdJson.commandJson,
      `handling command: ${LogFormat.cmdDetail(cmdJson)}`,
    )->Effect.runSync

    let query = Reventless.DcbTag.buildQueryFromCommand(
      ~eventTypes=queryEventTypes,
      ~schema=Spec.commandSchema,
      ~value=command'.command,
    )

    // Extract the entity ID from the command for use in Accepted outcomes.
    let entityId = switch derivedPartitionTag {
    | Simple(pt) => Reventless.DcbTag.getPartitionTagValue(query, pt)
    | Composite(spec) =>
      let tags = Reventless.DcbTag.extractTags(Spec.commandSchema, command'.command)
      Some(Reventless.DcbTag.getCompositePartitionKeyValue(tags, spec))
    }

    let rec attempt = (~retries) =>
      dcbEventLog.readStream(~query)
      ->Stream.map(raw => {
        let decoded = decoder.decode(
          ~eventType=raw.eventType,
          ~data=raw.data->JSON.Decode.object->Option.getOr(Dict.make()),
        )
        decoded->Option.map(event => (event, raw.position))
      })
      ->Stream.flatMap(opt =>
        switch opt {
        | Some(v) => Stream.fromIterable([v])
        | None => Stream.empty
        }
      )
      ->Stream.runFold((Spec.initialState, None, 0), ((dm, _pos, n), (event, position)) => (
        Spec.evolve(dm, event),
        Some(position),
        n + 1,
      ))
      ->Effect.tap(((_, _, n)) => EffectLogger.logInfo(~comp, `read: ${n->Int.toString} event(s)`))
      ->Effect.flatMap(((state, headPosition, _)) =>
        switch Spec.decide(state, command'.command) {
        | Ok(newEvents) if newEvents->Array.length == 0 =>
          CommandTopic_Helpers.reportAccepted(
            cmdJson.meta.msgId,
            switch entityId {
            | Some(eid) => {entityId: eid, eventCount: 0}
            | None => {eventCount: 0}
            },
          )
          EffectLogger.logInfo(~comp, "no events produced")->Effect.map(_ => Ok("ok"))
        | Ok(newEvents) =>
          let rawEvents = newEvents->Array.map(encodeEvent)
          let eventCount = rawEvents->Array.length->Int.toString
          let eventDetails =
            rawEvents
            ->Array.map(e => {
              let fields = switch e.data {
              | Object(dict) =>
                let f =
                  dict
                  ->Dict.toArray
                  ->Array.map(((k, v)) => `${k}:${v->JSON.stringify}`)
                  ->Array.join(",")
                f == "" ? "" : `({${f}})`
              | _ => ""
              }
              `${LogFormat.bold(e.eventType)}${fields}`
            })
            ->Array.join(", ")
          let eventJsons = rawEvents->Array.map(e => e.data)->JSON.Encode.array
          let condition: Reventless.DcbTag.appendCondition = {
            query,
            after: ?headPosition,
          }
          EffectLogger.logInfo(~comp, ~detail=eventJsons, `produced ${eventCount} event(s): [${eventDetails}]`)
          ->Effect.flatMap(_ => Effect.promise(() => dcbEventLog.append(rawEvents, ~condition)))
          ->Effect.flatMap(appendResult =>
            switch appendResult {
            | Ok(_position) =>
              CommandTopic_Helpers.reportAccepted(
                cmdJson.meta.msgId,
                switch entityId {
                | Some(eid) => {entityId: eid, eventCount: rawEvents->Array.length}
                | None => {eventCount: rawEvents->Array.length}
                },
              )
              EffectLogger.logInfo(~comp, `append: ${eventCount} event(s)`)->Effect.map(
                _ => Ok("ok"),
              )
            | Error(_err) =>
              if retries > 0 {
                EffectLogger.logWarn(
                  ~comp,
                  `conflict, retrying ${(maxRetries - retries + 1)
                      ->Int.toString}/${maxRetries->Int.toString}`,
                )->Effect.flatMap(_ => attempt(~retries=retries - 1))
              } else {
                EffectLogger.logError(~comp, "conflict, retries exhausted")->Effect.map(
                  _ => Error("conflict: retries exhausted"),
                )
              }
            }
          )
        | Error(error) =>
          let errorJson = error->S.reverseConvertToJsonOrThrow(Spec.errorSchema)->JSON.stringify
          EffectLogger.logError(~comp, `decide error=${errorJson}`)->Effect.map(_ => Ok("rejected"))
        }
      )

    attempt(~retries=maxRetries)
  }

  // CommandTopic handler — processes each command sequentially through handleSingleCommand,
  // returning Ok(reference) or Error(reference) per command.
  let handleCommands = (dcbEventLog, stream) =>
    stream
    ->Stream.mapEffect(({ReventlessInfra.CommandTopic.reference: reference, command}) =>
      handleSingleCommand(dcbEventLog, command)->Effect.map(result =>
        switch result {
        | Ok(_) => Ok(reference)
        | Error(_) => Error(reference)
        }
      )
    )
    ->Stream.runCollect
}
