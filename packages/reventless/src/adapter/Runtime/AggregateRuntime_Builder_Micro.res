module Make = (
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel,
  EventCollectorChannel: EventCollector_Adapter.Channel,
): (
  AggregateRuntime_Builder.T
    with type context = RuntimeEnvironment.context
    and type runtimeParts = RuntimeEnvironment.parts
    and module CommandTopicChannel = CommandTopicChannel
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = RuntimeEnvironment.context
  type runtimeParts = RuntimeEnvironment.parts
  module CommandTopicChannel = CommandTopicChannel
  module EventCollectorChannel = EventCollectorChannel

  let forCommandGenerator = (
    ~handler: Pulumi.Output.t<CommandGenerator.eventHandler<context>>,
    ~memorySize=1024,
    ~timeout=30,
    commandGenerator,
  ) => {
    let resource = commandGenerator->Component.toPulumiResource
    let handler = handler->Pulumi.Output.apply(handler => (payload, context) => {
      Js.log4(
        "AggregateRuntime_Builder_Micro.forCommandGenerator:",
        resource.name,
        payload,
        context,
      )
      handler(payload, context)
    })
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(CommandGenerator.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }
  let forCommandTopic = (
    ~handler: Pulumi.Output.t<
      Runtime.eventHandler<CommandTopicChannel.callbackEvent, context, unit>,
    >,
    ~memorySize=1024,
    ~timeout=30,
    commandTopic,
  ) => {
    let resource = commandTopic->Component.toPulumiResource
    let handler = handler->Pulumi.Output.apply(handler => (event, context) => {
      Js.log4("AggregateRuntime_Builder_Micro.forCommandTopic:", resource.name, event, context)
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
  let forEventCollector = (
    ~handler: Pulumi.Output.t<
      Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    >,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector,
  ) => {
    let resource = eventCollector->Component.toPulumiResource
    let handler = handler->Pulumi.Output.apply(handler => (event, context) => {
      Js.log4("AggregateRuntime_Builder_Micro.forEventCollector:", resource.name, event, context)
      handler(event, context)
    })
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(EventCollector.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }
}
