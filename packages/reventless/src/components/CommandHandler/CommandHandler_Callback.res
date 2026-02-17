module type Ops = {
  module Spec: CommandHandler.Spec
  let dcbEventLog: DcbEventLog.operations<Spec.DcbEventLogSpec.event>
}

module type T = {
  module Spec: CommandHandler.Spec
  let handleCommands: CommandTopic.commandsHandler<
    Message.command'<ReventlessSpec.Id.String.t, Spec.command>,
  >
}

module Make = (Spec: CommandHandler.Spec, Ops: Ops with module Spec = Spec): (
  T with module Spec = Spec
) => {
  module Spec = Spec

  let maxRetries = 3

  let handleSingleCommand = async (
    command': Message.command'<ReventlessSpec.Id.String.t, Spec.command>,
  ) => {
    let commandTags = DcbTag.extractTags(Spec.commandSchema, command'.command)
    let query: DcbTag.query = [
      {
        eventTypes: Spec.queryEventTypes,
        tags: commandTags,
      },
    ]

    let rec attempt = async (~retries) => {
      let readResult = await Ops.dcbEventLog.read(~query)

      let decisionModel =
        readResult.events
        ->Array.map(se => se.event)
        ->Array.reduce(Spec.initialDecisionModel, Spec.reduce)

      switch Spec.decide(decisionModel, command'.command) {
      | Ok(newEvents) if newEvents->Array.length == 0 =>
        Logger.debug(~loc=__LOC__, `CommandHandler(${Spec.name})`, "no events generated")
        Ok("ok")
      | Ok(newEvents) =>
        let condition: DcbTag.appendCondition = {
          query,
          after: ?readResult.headPosition,
        }
        switch await Ops.dcbEventLog.append(newEvents, ~condition) {
        | Ok(_position) =>
          Logger.debug(
            ~loc=__LOC__,
            `CommandHandler(${Spec.name})`,
            `${newEvents->Array.length->Int.toString} event(s) appended`,
          )
          Ok("ok")
        | Error(err) =>
          if retries > 0 {
            Logger.info(~loc=__LOC__, `CommandHandler(${Spec.name}): conflict, retrying`, err)
            await attempt(~retries=retries - 1)
          } else {
            Logger.error(
              ~loc=__LOC__,
              `CommandHandler(${Spec.name}): conflict, retries exhausted`,
              err,
            )
            Error("conflict: retries exhausted")
          }
        }
      | Error(error) =>
        let errorJson = error->S.reverseConvertToJsonOrThrow(Spec.errorSchema)->JSON.stringify
        Logger.error(~loc=__LOC__, `CommandHandler(${Spec.name}): decide error`, errorJson)
        Error(errorJson)
      }
    }

    await attempt(~retries=maxRetries)
  }

  let handleCommands = async topicItems => {
    Logger.debug(~loc=__LOC__, "starting", "CommandHandler.handleCommands")
    let results = await topicItems
    ->Array.map(async ({CommandTopic.reference: reference, command}) => {
      switch await handleSingleCommand(command) {
      | Ok(_) => Ok(reference)
      | Error(_) => Error(reference)
      }
    })
    ->Promise.all
    results
  }
}
