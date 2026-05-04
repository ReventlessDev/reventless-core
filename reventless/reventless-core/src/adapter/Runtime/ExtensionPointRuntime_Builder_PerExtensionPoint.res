module Make = (
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel,
): (
  ExtensionPointRuntime_Builder.T
    with type context = RuntimeEnvironment.context
    and type runtimeParts = RuntimeEnvironment.parts
    and module CommandTopicChannel = CommandTopicChannel
) => {
  type context = RuntimeEnvironment.context
  type runtimeParts = RuntimeEnvironment.parts
  module CommandTopicChannel = CommandTopicChannel

  let forCommandTopic = (
    ~handler,
    ~connect,
    ~memorySize=1024,
    ~timeout=30,
    ~specModulePath as _,
    ~mappingsModulePath as _,
    ~publishToAggregatesQueueUrls as _,
    commandTopic,
  ) => {
    let resource = commandTopic->Component.toPulumiResource
    let runtime = RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(CommandTopic.componentType),
      ~handler=handler->Pulumi.Output.apply(handler =>
        handler->RuntimeEnvironment.asEffectHandler->Runtime.runEffectHandler
      ),
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
    connect(~runtime)
  }
}
