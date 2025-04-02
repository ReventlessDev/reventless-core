module Make = (RuntimeEnvironment: Runtime.Environment): (
  Runtime_Builder.T
    with type context = RuntimeEnvironment.context
    and type parts = RuntimeEnvironment.parts
) => {
  type context = RuntimeEnvironment.context
  type parts = RuntimeEnvironment.parts

  let forAggregateCommandGenerator = (
    ~handler,
    ~memorySize=1024,
    ~timeout=30,
    commandGenerator,
  ) => {
    let resource = commandGenerator->Component.toPulumiResource
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(CommandGenerator.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }
  let forAggregateCommandTopic = (~handler, ~memorySize=1024, ~timeout=30, commandTopic) => {
    let resource = commandTopic->Component.toPulumiResource
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(CommandTopic.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }
  let forAggregateEventCollector = (~handler, ~memorySize=1024, ~timeout=30, eventCollector) => {
    let resource = eventCollector->Component.toPulumiResource
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(EventCollector.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }
  let forReadModelEventCollector = (~handler, ~memorySize=1024, ~timeout=30, eventCollector) => {
    let resource = eventCollector->Component.toPulumiResource
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(EventCollector.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }
  let forExtensionPointCommandTopic = (~handler, ~memorySize=1024, ~timeout=30, commandTopic) => {
    let resource = commandTopic->Component.toPulumiResource
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(CommandTopic.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }
  let forSideEffectHandlerEventCollector = (
    ~handler,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector,
  ) => {
    let resource = eventCollector->Component.toPulumiResource
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(SideEffectHandler.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }

  let forPluginEventCollector = (~handler, ~memorySize=1024, ~timeout=30, eventCollector) => {
    let resource = eventCollector->Component.toPulumiResource
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(EventCollector.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }

  let forPluginHeartbeat = (~handler, ~memorySize=1024, ~timeout=30, heartbeat) => {
    let resource = heartbeat->Component.toPulumiResource
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(Heartbeat.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }

  let forDeadLetterQueue = (~handler, ~memorySize=1024, ~timeout=30, plugin) => {
    let resource = plugin->Component.toPulumiResource
    RuntimeEnvironment.make(
      ~name=resource.name->Option.getOr("DeadLetterQueue"),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }
}
