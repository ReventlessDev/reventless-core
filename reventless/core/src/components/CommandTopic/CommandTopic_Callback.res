module type Ops = {
  module Spec: ReventlessInfra.CommandTopic.T
  let commandsHandler: CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>
}

module type T = {
  let handleJsonCommands: CommandTopic.jsonCommandsHandler
}

module Make = (Spec: ReventlessInfra.CommandTopic.T, Ops: Ops with module Spec = Spec): T => {
  let comp = `CommandTopic(${Spec.name})`

  let handleJsonCommands: CommandTopic.jsonCommandsHandler = stream =>
    stream
    ->Stream.mapEffect(({ReventlessInfra.CommandTopic.reference: reference, command: json}) =>
      Effect.sync(() =>
        switch json->Message.decodeCommand'(Spec.Id.schema, Spec.commandSchema) {
        | command' => Some({ReventlessInfra.CommandTopic.reference, command: command'})
        | exception err =>
          let commandStr = json->JSON.stringify
          let errMsg = err->Reventless.Util_Sury.exnMessage
          EffectLogger.logError(
            ~comp,
            `decode failed: ${commandStr} err=${errMsg}`,
          )->Effect.runSync
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
}
