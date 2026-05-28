module type T = {
  module Spec: Reventless.StateChangeSlice.Spec
  module Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec
  let handleCommands: (
    DcbEventLog.operations,
    Stream.t<
      CommandTopic.topicItem<Message.command'<Reventless.Id.String.t, Spec.command>>,
      string,
      unit,
    >,
  ) => Effect.t<array<result<string, string>>, string, unit>
}

module Make = (
  Spec: Reventless.StateChangeSlice.Spec,
  Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec,
): (T with module Spec = Spec and module Behavior := Behavior) => {
  module Spec = Spec
  module Behavior = Behavior

  let comp = `StateChangeSlice(${Spec.name})`

  let decoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)
  let queryEventTypes = decoder.eventTypes

  let encodeEvent = (
    ~parentMeta: Message.meta,
    event: Spec.event,
  ): ReventlessInfra.DcbEventLog.rawEvent => {
    let json = event->JSON.stringifyAny->Option.getOrThrow->JSON.parseOrThrow
    let (eventType, data) = json->Message.splitMessage
    // Use `extractTagsExpanded` (not `extractTags`) so per-element tags on
    // `array<string>` fields are emitted — e.g. OrderPlaced's
    // `productIds: array<string>` produces one tag per productId rather than
    // dropping the field entirely. Without expansion the stored event has no
    // productId tag, so the next slice reading by productId can't see this
    // event, while the query path (`buildQueryFromCommand`, which DOES use
    // the expanded variant) still bumps `fence#productId:<x>`. Result:
    // subsequent PlaceOrder for the same productId reads stale events,
    // computes after < current fence, and conflicts. Expanding here keeps
    // the two paths in sync.
    let tags =
      Reventless.DcbTag.extractTagsExpanded(Spec.eventSchema, event)
      ->Array.concat([{Reventless.DcbTag.key: "originatorSlice", value: Spec.name}])
    // Inherit service from the triggering command — the DcbEventLog publish path
    // overrides service to `<name>DcbEventLog` for routing so EventCollector
    // subscriptions still match.
    let meta = Message.deriveMeta(~parent=parentMeta)
    {eventType, data: JSON.Object(data), tags, meta}
  }

  // Computed once at functor init — used to extract entityId for publishJsonsAndWait outcomes.
  let derivedPartitionTag = Reventless.DcbTag.derivePartitionTag([
    (Spec.name, Behavior.moduleUrl, Spec.eventSchema->S.castToUnknown),
  ])

  let maxRetries = 3

  // Processes one command against the DCB event log with optimistic concurrency:
  //   1. Reads relevant events (filtered by command tags) to build the decision model
  //   2. Decodes raw events using consumedEventSchema
  //   3. Calls Behavior.decide to produce new events
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
      ->Stream.runFold((Behavior.initialState, None, 0), ((dm, _pos, n), (event, position)) => (
        Behavior.evolve(dm, event),
        Some(position),
        n + 1,
      ))
      ->Effect.tap(((_, _, n)) => EffectLogger.logInfo(~comp, `read: ${n->Int.toString} event(s)`))
      ->Effect.flatMap(((state, headPosition, _)) =>
        switch Behavior.decide(state, command'.command) {
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
          let rawEvents = newEvents->Array.map(e => encodeEvent(~parentMeta=command'.meta, e))
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
            | Error(err) =>
              if retries > 0 {
                EffectLogger.logWarn(
                  ~comp,
                  `append failed (retrying ${(maxRetries - retries + 1)
                      ->Int.toString}/${maxRetries->Int.toString}): ${err}`,
                )->Effect.flatMap(_ => attempt(~retries=retries - 1))
              } else {
                let errorCode = err->String.startsWith("Conflict") ? "Conflict" : "AppendFailed"
                CommandTopic_Helpers.reportRejected(
                  cmdJson.meta.msgId,
                  {errorCode, errorDetail: err},
                )
                EffectLogger.logError(
                  ~comp,
                  `append failed, retries exhausted: ${err}`,
                )->Effect.map(_ => Error(err))
              }
            }
          )
        | Error(error) =>
          let errorJson = error->S.reverseConvertToJsonOrThrow(Spec.errorSchema)
          let errorCode = errorJson->Message.variantNameOfJson
          let (_, payloadDict) = errorJson->Message.splitMessage
          let errorDetail =
            payloadDict->Dict.toArray->Array.length == 0
              ? ""
              : payloadDict->JSON.Encode.object->JSON.stringify
          CommandTopic_Helpers.reportRejected(cmdJson.meta.msgId, {errorCode, errorDetail})
          EffectLogger.logError(
            ~comp,
            `decide rejected: ${errorCode} ${errorDetail}`,
          )->Effect.map(_ => Ok("rejected"))
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
