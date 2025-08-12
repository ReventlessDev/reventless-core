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
          service: ReventlessSpec.PluginExtensionPointSpec.name,
          time: Message.nowAsISOString(),
          ip: "",
          user: "Heartbeat",
          msgId,
          correlationId: msgId,
        },
        commandJson: ReventlessSpec.PluginExtensionPointSpec.Heartbeat(
          Spec.timeout,
        )->Message.encode(ReventlessSpec.PluginExtensionPointSpec.commandSchema),
        delay: None,
      },
    ])
  }
}
