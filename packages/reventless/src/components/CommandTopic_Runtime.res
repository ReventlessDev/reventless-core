open ReventlessSpec.CommandTopic

module Make = (Spec: ReventlessSpec.CommandTopic.Spec) => {
  let handleCommands = commandsHandler =>
    async jsonItems => {
      Logger.debug(
        ~loc=__LOC__,
        "starting handleCommands. Command count",
        jsonItems->Belt.Array.size,
      )
      let topicItems = jsonItems->Belt.Array.keepMap(({reference, command: json}) =>
        switch json->Message.command'_decode(Spec.Id.t_decode, Spec.command_decode, _) {
        | Belt_Result.Ok(command') => Some({reference, command: command'})
        | Belt_Result.Error(err) =>
          let commandStr = json->Js.Json.stringify
          Logger.error(~loc=__LOC__, `Couldn't decode command ${commandStr}`, err.message)
          None
        }
      )
      switch await commandsHandler(topicItems) {
      | res =>
        Logger.debug(~loc=__LOC__, "finished", "CommandTopic.handleCommands")
        res
      | exception Js.Exn.Error(e) =>
        Logger.error(~loc=__LOC__, "Couldn't handle commands", e)
        Js.Exn.raiseError(__LOC__ ++ `Error: Couldn't handle commands`) // TODO: exception details
      }
    }
}
