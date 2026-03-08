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

  // Processes one command against the DCB event log with optimistic concurrency:
  //   1. Reads relevant events (filtered by command tags) to build the decision model
  //   2. Calls Spec.decide to produce new events
  //   3. Appends with a condition (no new matching events since read)
  //   4. On conflict, retries from step 1 (up to maxRetries)
  let handleSingleCommand = (
    dcbEventLog: DcbEventLog.operations<Spec.DcbEventLogSpec.event>,
    command': Message.command'<Reventless.Id.String.t, Spec.command>,
  ) => {
    let query = Reventless.DcbTag.buildQueryFromCommand(
      ~eventTypes=queryEventTypes,
      ~schema=Spec.commandSchema,
      ~value=command'.command,
    )

    let rec attempt = (~retries) =>
      dcbEventLog.readStream(~query)
      ->Stream.runFold((Spec.initialDecisionModel, None), ((dm, _pos), se) => (
        Spec.reduce(dm, se.event),
        Some(se.position),
      ))
      ->Effect.flatMap(((decisionModel, headPosition)) =>
        switch Spec.decide(decisionModel, command'.command) {
        | Ok(newEvents) if newEvents->Array.length == 0 =>
          Effect.logInfo(`StateChangeSlice(${Spec.name}): no events generated`)->Effect.map(_ => Ok(
            "ok",
          ))
        | Ok(newEvents) =>
          let condition: Reventless.DcbTag.appendCondition = {
            query,
            after: ?headPosition,
          }
          Effect.promise(() =>
            dcbEventLog.append(newEvents, ~condition)
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
