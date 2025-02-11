module type Spec = {
  let publishToCorePluginExtensionPoint: ReventlessSpec.CommandTopic.publishJsons
  let id: string
  let timeout: int
}

module Make = (Spec: Spec) => {
  let heartbeat = () => {
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
        commandJson: {
          open ReventlessSpec.PluginExtensionPointSpec
          Heartbeat(Spec.timeout)->command_encode
        },
        delay: None,
      },
    ])
  }
}
