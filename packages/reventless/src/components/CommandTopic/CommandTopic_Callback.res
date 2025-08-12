module type Ops = {
  module Spec: CommandTopic.Spec
  let commandsHandler: CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>
}

module type T = {
  let handleJsonCommands: CommandTopic.jsonCommandsHandler
}

module Make = (Spec: CommandTopic.Spec, Ops: Ops with module Spec = Spec): T => {
  let handleJsonCommands = async jsonItems => {
    Logger.debug(~loc=__LOC__, "starting handleCommands. Command count", jsonItems->Array.length)
    let topicItems = jsonItems->Array.filterMap(({
      CommandTopic.reference: reference,
      command: json,
    }) =>
      switch json->Message.decodeCommand'(Spec.Id.schema, Spec.commandSchema) {
      | command' => Some({CommandTopic.reference, command: command'})
      | exception err =>
        let commandStr = json->Js.Json.stringify
        Logger.error(~loc=__LOC__, `Couldn't decode command ${commandStr}:`, err)
        None
      }
    )
    switch await Ops.commandsHandler(topicItems) {
    | res =>
      Logger.debug(~loc=__LOC__, "finished", "CommandTopic.handleCommands")
      res
    | exception Js.Exn.Error(e) =>
      Logger.error(~loc=__LOC__, "Couldn't handle commands", e)
      Js.Exn.raiseError(__LOC__ ++ `Error: Couldn't handle commands`) // TODO: exception details
    }
  }
}
