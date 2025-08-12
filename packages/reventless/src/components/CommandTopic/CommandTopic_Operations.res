module type Ops = {
  let publishJsons: CommandTopic.publishJsons
}

module Make = (Spec: CommandTopic.Spec, Ops: Ops) => {
  let publishJsons = async cmdJsons =>
    switch await Ops.publishJsons(cmdJsons) {
    | exception e =>
      cmdJsons->Logger.logCmdJsons(
        ~level=Logger.Level.Error,
        ~loc=__LOC__,
        "Couldn't publish commands",
      )
      raise(e)
    | _ => cmdJsons->Logger.logCmdJsons(~loc=__LOC__, "Published commands")
    }

  let publish = (command': Message.command'<Spec.Id.t, Spec.command>) => {
    let commandJson = {
      Message.id: command'.id->Spec.Id.toString,
      meta: command'.meta,
      commandJson: command'.command->Message.encode(Spec.commandSchema),
      delay: None,
    }
    Ops.publishJsons([commandJson])
  }
}
