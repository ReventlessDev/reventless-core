module type Ops = {
  module Spec: CommandTopic.Spec
  let commandsHandler: CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>
}

module Make = (Spec: CommandTopic.Spec, Ops: Ops) => {
  let handleJsonCommands = async jsonItems => {
    Logger.debug(~loc=__LOC__, "starting handleCommands. Command count", jsonItems->Belt.Array.size)
    let topicItems = jsonItems->Belt.Array.keepMap(({
      CommandTopic.reference: reference,
      command: json,
    }) =>
      switch json->Message.command'_decode(Spec.Id.t_decode, Spec.command_decode, _) {
      | Belt_Result.Ok(command') => Some({CommandTopic.reference, command: command'})
      | Belt_Result.Error(err) =>
        let commandStr = json->Js.Json.stringify
        Logger.error(~loc=__LOC__, `Couldn't decode command ${commandStr}`, err.message)
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
