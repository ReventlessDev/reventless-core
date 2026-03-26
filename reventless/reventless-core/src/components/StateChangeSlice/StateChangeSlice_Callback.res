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

  let decoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)
  let queryEventTypes = decoder.eventTypes

  let encodeProducedEvent = (event: Spec.producedEvent): ReventlessInfra.DcbEventLog.rawEvent => {
    let json = event->S.reverseConvertToJsonOrThrow(Spec.producedEventSchema)
    let (eventType, data) = json->Message.splitMessage
    let tags = Reventless.DcbTag.extractTags(Spec.producedEventSchema, event)
    {eventType, data: JSON.Object(data), tags}
  }

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
    let query = Reventless.DcbTag.buildQueryFromCommand(
      ~eventTypes=queryEventTypes,
      ~schema=Spec.commandSchema,
      ~value=command'.command,
    )

    let rec attempt = (~retries) =>
      dcbEventLog.readStream(~query)
      ->Stream.map(raw => {
        let decoded = decoder.decode(~eventType=raw.eventType, ~data=raw.data->JSON.Decode.object->Option.getOr(Dict.make()))
        decoded->Option.map(event => (event, raw.position))
      })
      ->Stream.flatMap(opt =>
        switch opt {
        | Some(v) => Stream.fromIterable([v])
        | None => Stream.empty
        }
      )
      ->Stream.runFold((Spec.initialState, None), ((dm, _pos), (event, position)) => (
        Spec.evolve(dm, event),
        Some(position),
      ))
      ->Effect.flatMap(((state, headPosition)) =>
        switch Spec.decide(state, command'.command) {
        | Ok(newEvents) if newEvents->Array.length == 0 =>
          Effect.logInfo(`StateChangeSlice(${Spec.name}): no events generated`)->Effect.map(_ => Ok(
            "ok",
          ))
        | Ok(newEvents) =>
          let rawEvents = newEvents->Array.map(encodeProducedEvent)
          let condition: Reventless.DcbTag.appendCondition = {
            query,
            after: ?headPosition,
          }
          Effect.promise(() =>
            dcbEventLog.append(rawEvents, ~condition)
          )->Effect.flatMap(appendResult =>
            switch appendResult {
            | Ok(_position) =>
              Effect.logInfo(
                `StateChangeSlice(${Spec.name}): ${newEvents
                  ->Array.length
                  ->Int.toString} event(s) appended`,
              )->Effect.map(_ => Ok("ok"))
            | Error(_err) =>
              if retries > 0 {
                Effect.logInfo(
                  `StateChangeSlice(${Spec.name}): conflict, retrying`,
                )->Effect.flatMap(_ => attempt(~retries=retries - 1))
              } else {
                Effect.logError(
                  `StateChangeSlice(${Spec.name}): conflict, retries exhausted`,
                )->Effect.map(_ => Error("conflict: retries exhausted"))
              }
            }
          )
        | Error(error) =>
          let errorJson = error->S.reverseConvertToJsonOrThrow(Spec.errorSchema)->JSON.stringify
          Effect.logError(
            `StateChangeSlice(${Spec.name}): decide error: ${errorJson}`,
          )->Effect.map(_ => Error(errorJson))
        }
      )

    attempt(~retries=maxRetries)
  }

  // CommandTopic handler — processes each command sequentially through handleSingleCommand,
  // returning Ok(reference) or Error(reference) per command.
  let handleCommands = (dcbEventLog, stream) =>
    Effect.logInfo("starting StateChangeSlice.handleCommands")->Effect.zipRight(
      stream
      ->Stream.mapEffect(({ReventlessInfra.CommandTopic.reference: reference, command}) =>
        handleSingleCommand(dcbEventLog, command)->Effect.map(result =>
          switch result {
          | Ok(_) => Ok(reference)
          | Error(_) => Error(reference)
          }
        )
      )
      ->Stream.runCollect,
    )
}
