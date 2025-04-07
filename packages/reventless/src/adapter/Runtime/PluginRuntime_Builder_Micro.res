module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel,
): (
  PluginRuntime_Builder.T
    with type context = RuntimeEnvironment.context
    and type runtimeParts = RuntimeEnvironment.parts
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = RuntimeEnvironment.context
  type runtimeParts = RuntimeEnvironment.parts
  module EventCollectorChannel = EventCollectorChannel

  let forSideEffectHandlerEventCollector = (
    ~handler,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector,
  ) => {
    let resource = eventCollector->Component.toPulumiResource
    let handler = handler->Pulumi.Output.apply(handler => (event, context) => {
      Js.log4(
        "PluginRuntime_Builder_Micro.forSideEffectHandlerEventCollector:",
        resource.name,
        event,
        context,
      )
      handler(event, context)
    })
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
    let handler = handler->Pulumi.Output.apply(handler => (event, context) => {
      Js.log4("PluginRuntime_Builder_Micro.forPluginEventCollector:", resource.name, event, context)
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

  let forPluginHeartbeat = (~handler, ~memorySize=1024, ~timeout=30, heartbeat) => {
    let resource = heartbeat->Component.toPulumiResource
    let handler = handler->Pulumi.Output.apply(handler => (event, context) => {
      Js.log4("PluginRuntime_Builder_Micro.forPluginHeartbeat:", resource.name, event, context)
      handler(event, context)
    })
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(Heartbeat.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }

  // let forDeadLetterQueue = (~handler, ~memorySize=1024, ~timeout=30, plugin) => {
  //   let resource = plugin->Component.toPulumiResource
  //   RuntimeEnvironment.make(
  //     ~name=resource.name->Option.getOr("DeadLetterQueue"),
  //     ~handler,
  //     ~memorySize,
  //     ~timeout,
  //     ~opts={Pulumi.ComponentResource.parent: resource},
  //   )
  // }
}
