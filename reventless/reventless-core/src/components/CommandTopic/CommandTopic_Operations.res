module type Ops = {
  let publishJsons: CommandTopic.publishJsons
}

module Make = (Spec: ReventlessInfra.CommandTopic.T, Ops: Ops) => {
  let publishJsons = async cmdJsons =>
    switch await Ops.publishJsons(cmdJsons) {
    | exception e =>
      cmdJsons
      ->LogFormat.commandJsonsToLogMessages
      ->Array.forEach(msg => Effect.logError("Couldn't publish commands: " ++ msg)->Effect.runSync)
      throw(e)
    | _ =>
      cmdJsons
      ->LogFormat.commandJsonsToLogMessages
      ->Array.forEach(msg => Effect.logInfo("Published commands: " ++ msg)->Effect.runSync)
    }

  let publish = (command': Message.command'<Spec.Id.t, Spec.command>) => {
    let commandJson = {
      Message.id: command'.id->Spec.Id.toString,
      meta: command'.meta,
      commandJson: command'.command->Message.encode(Spec.commandSchema),
    }
    Ops.publishJsons([commandJson])
  }
}
