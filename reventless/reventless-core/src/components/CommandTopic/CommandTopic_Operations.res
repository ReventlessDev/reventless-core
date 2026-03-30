module type Ops = {
  let publishJsons: CommandTopic.publishJsons
}

module Make = (Spec: ReventlessInfra.CommandTopic.T, Ops: Ops) => {
  let comp = `CommandTopic(${Spec.name})`

  let publishJsons = async cmdJsons => {
    let count = cmdJsons->Array.length->Int.toString
    cmdJsons->Array.forEachWithIndex((cmdJson, idx) => {
      let idxStr = (idx + 1)->Int.toString
      EffectLogger.logInfo(
        ~comp,
        ~detail=cmdJson.Message.commandJson,
        `publishing command ${idxStr}/${count}: ${LogFormat.cmdDetail(cmdJson)}`,
      )->Effect.runSync
    })
    try {await Ops.publishJsons(cmdJsons)} catch {
    | exn =>
      cmdJsons->Array.forEachWithIndex((cmdJson, idx) => {
        let idxStr = (idx + 1)->Int.toString
        EffectLogger.logError(
          ~comp,
          ~detail=cmdJson.Message.commandJson,
          `publish failed ${idxStr}/${count}: ${LogFormat.cmdDetail(cmdJson)}`,
        )->Effect.runSync
      })
      throw(exn)
    }
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
