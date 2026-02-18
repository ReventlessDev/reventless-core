module type Ops = {
  module Spec: ReventlessSpec.CommandTopic_Spec.T
  let commandsHandler: CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>
}

module type T = {
  let handleJsonCommands: CommandTopic.jsonCommandsHandler
}

module Make = (Spec: ReventlessSpec.CommandTopic_Spec.T, Ops: Ops with module Spec = Spec): T => {
  let handleJsonCommands = async jsonItems => {
    Logger.debug(~loc=__LOC__, "starting handleCommands. Command count", jsonItems->Array.length)
    let topicItems = jsonItems->Array.filterMap(({
      CommandTopic.reference: reference,
      command: json,
    }) =>
      switch json->Message.decodeCommand'(Spec.Id.schema, Spec.commandSchema) {
      | command' => Some({CommandTopic.reference, command: command'})
      | exception err =>
        let commandStr = json->JSON.stringify
        Logger.error(~loc=__LOC__, `Couldn't decode command ${commandStr}:`, err)
        None
      }
    )
    switch await Ops.commandsHandler(topicItems) {
    | res =>
      Logger.debug(~loc=__LOC__, "finished", "CommandTopic.handleCommands")
      res
    | exception JsExn(e) =>
      Logger.error(~loc=__LOC__, "Couldn't handle commands", e)
      JsError.throwWithMessage(__LOC__ ++ `Error: Couldn't handle commands`) // TODO: exception details
    }
  }
}
