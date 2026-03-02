module type Ops = {
  module Spec: ReventlessInfra.CommandTopic.T
  let commandsHandler: CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>
}

module type T = {
  let handleJsonCommands: CommandTopic.jsonCommandsHandler
}

module Make = (Spec: ReventlessInfra.CommandTopic.T, Ops: Ops with module Spec = Spec): T => {
  let handleJsonCommands: CommandTopic.jsonCommandsHandler = stream =>
    stream
    ->Stream.mapEffect(({ReventlessInfra.CommandTopic.reference: reference, command: json}) =>
      Effect.sync(() =>
        switch json->Message.decodeCommand'(Spec.Id.schema, Spec.commandSchema) {
        | command' => Some({ReventlessInfra.CommandTopic.reference, command: command'})
        | exception err =>
          let commandStr = json->JSON.stringify
          Logger.error(~loc=__LOC__, `Couldn't decode command ${commandStr}:`, err)
          None
        }
      )
    )
    ->Stream.flatMap(opt =>
      switch opt {
      | Some(v) => Stream.fromIterable([v])
      | None => Stream.empty
      }
    )
    ->Ops.commandsHandler
    ->Effect.map(res => {
      Logger.debug(~loc=__LOC__, "finished", "CommandTopic.handleCommands")
      res
    })
}
