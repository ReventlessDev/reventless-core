module type T = {
  module Spec: Reventless.StateChangeSlice.Spec
  let handleCommands: (
    DcbEventLog.operations<Spec.DcbEventLogSpec.event>,
    Stream.t<
      CommandTopic.topicItem<Message.command'<Reventless.Id.String.t, Spec.command>>,
      string,
      unit,
    >,
  ) => Effect.t<array<result<string, string>>, string, unit>
}

module Make = (Spec: Reventless.StateChangeSlice.Spec): (T with module Spec = Spec) => {
  module Spec = Spec

  let queryEventTypes = Reventless.DcbTag.extractEventTypes(Spec.DcbEventLogSpec.eventSchema)

  let maxRetries = 3

  let handleSingleCommand = async (
    dcbEventLog: DcbEventLog.operations<Spec.DcbEventLogSpec.event>,
    command': Message.command'<Reventless.Id.String.t, Spec.command>,
  ) => {
    let commandTags = Reventless.DcbTag.extractTags(Spec.commandSchema, command'.command)
    let query: Reventless.DcbTag.query = [
      {
        eventTypes: queryEventTypes,
        tags: commandTags,
      },
    ]

    let rec attempt = async (~retries) => {
      let (decisionModel, headPosition) = await dcbEventLog.readStream(~query)
      ->Stream.runFold((Spec.initialDecisionModel, None), ((dm, _pos), se) => (
        Spec.reduce(dm, se.event),
        Some(se.position),
      ))
      ->Effect.runPromise

      switch Spec.decide(decisionModel, command'.command) {
      | Ok(newEvents) if newEvents->Array.length == 0 =>
        Effect.logInfo(`StateChangeSlice(${Spec.name}): no events generated`)->Effect.runSync
        Ok("ok")
      | Ok(newEvents) =>
        let condition: Reventless.DcbTag.appendCondition = {
          query,
          after: ?headPosition,
        }
        switch await dcbEventLog.append(newEvents, ~condition) {
        | Ok(_position) =>
          Effect.logInfo(
            `StateChangeSlice(${Spec.name}): ${newEvents
              ->Array.length
              ->Int.toString} event(s) appended`,
          )->Effect.runSync
          Ok("ok")
        | Error(err) =>
          if retries > 0 {
            Effect.logInfo(`StateChangeSlice(${Spec.name}): conflict, retrying`)->Effect.runSync
            await attempt(~retries=retries - 1)
          } else {
            Effect.logError(
              `StateChangeSlice(${Spec.name}): conflict, retries exhausted`,
            )->Effect.runSync
            Error("conflict: retries exhausted")
          }
        }
      | Error(error) =>
        let errorJson = error->S.reverseConvertToJsonOrThrow(Spec.errorSchema)->JSON.stringify
        Effect.logError(
          `StateChangeSlice(${Spec.name}): decide error: ${errorJson}`,
        )->Effect.runSync
        Error(errorJson)
      }
    }

    await attempt(~retries=maxRetries)
  }

  let handleCommands = (dcbEventLog, stream) => {
    Effect.logInfo("starting StateChangeSlice.handleCommands")->Effect.runSync
    stream
    ->Stream.mapEffect(({ReventlessInfra.CommandTopic.reference: reference, command}) =>
      Effect.promise(async () => {
        switch await handleSingleCommand(dcbEventLog, command) {
        | Ok(_) => Ok(reference)
        | Error(_) => Error(reference)
        }
      })
    )
    ->Stream.runCollect
  }
}
