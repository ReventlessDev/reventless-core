module type Spec = {
  let publishToCorePluginExtensionPoint: CommandTopic.publishJsons
  let id: string
  let timeout: int
}

module Make = (Spec: Spec) => {
  let heartbeat = (_, _) => {
    let msgId = Message.uuid()
    Spec.publishToCorePluginExtensionPoint([
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
