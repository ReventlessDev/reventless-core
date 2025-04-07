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

  let forCommandTopic = (~handler, ~memorySize=1024, ~timeout=30, commandTopic) => {
    let resource = commandTopic->Component.toPulumiResource
    let handler = handler->Pulumi.Output.apply(handler => (event, context) => {
      Js.log4("ExtensionPointRuntime_Builder_Micro.forCommandTopic:", resource.name, event, context)
      handler(event, context)
    })
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(CommandTopic.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }
}
