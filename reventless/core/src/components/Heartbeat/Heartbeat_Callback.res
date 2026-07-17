module PluginExtensionPointSpec = ReventlessInfra.PluginExtensionPointSpec

module type Spec = {
  let publishToPluginExtensionPoint: CommandTopic.publishJsons
  let id: string
  let timeout: int
}

module Make = (Spec: Spec) => {
  let log = Logger.fromEnv()

  let heartbeat = (_, _) => {
    let msgId = Message.uuid()
    log.info(~comp="Heartbeat", `id=${Spec.id} timeout=${Spec.timeout->Int.toString}s`)
    Spec.publishToPluginExtensionPoint([
      {
        Message.id: Spec.id,
        meta: {
          service: PluginExtensionPointSpec.name,
          time: Message.nowAsISOString(),
          ip: "",
          user: "Heartbeat",
          msgId,
          correlationId: msgId,
        },
        commandJson: PluginExtensionPointSpec.Heartbeat(
          Spec.timeout,
        )->Message.encode(PluginExtensionPointSpec.commandSchema),
      },
    ])
  }
}
