module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
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
    ~eventTopics: EventTopic.allOutputs,
    ~resources: array<ReventlessSpec.Adapter.resource>,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector,
  ) => {
    let resource = eventCollector->Component.toPulumiResource
    let name = resource.name->ComponentType.nameOpt(SideEffectHandler.componentType)
    let opts = {Pulumi.ComponentResource.parent: resource}
    let runtime = RuntimeEnvironment.make(
      ~name,
      ~handler=handler->Pulumi.Output.apply(handler => handler->RuntimeEnvironment.asEventHandler),
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
    let channel = eventCollector->EventCollector_Adapter.channel
    let _connectResources = EventCollectorChannel.connect(
      ~name,
      ~channelSpecs=[{channel, eventTopics, resources}],
      ~runtime,
      ~opts,
    )
  }

  let forPluginEventCollector = (
    ~handler,
    ~eventTopics: EventTopic.allOutputs,
    ~resources: array<ReventlessSpec.Adapter.resource>,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector,
  ) => {
    let resource = eventCollector->Component.toPulumiResource
    let name = resource.name->ComponentType.nameOpt(EventCollector.componentType)
    let opts = {Pulumi.ComponentResource.parent: resource}
    let runtime = RuntimeEnvironment.make(
      ~name,
      ~handler=handler->Pulumi.Output.apply(handler => handler->RuntimeEnvironment.asEventHandler),
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
    let _connectResources = EventCollectorChannel.connect(
      ~name,
      ~channelSpecs=[
        {channel: eventCollector->EventCollector_Adapter.channel, eventTopics, resources},
      ],
      ~runtime,
      ~opts,
    )
  }

  let forPluginHeartbeat = (
    ~handler: Pulumi.Output.t<(unit, RuntimeEnvironment.context) => promise<'a>>,
    ~connect,
    ~memorySize=1024,
    ~timeout=30,
    heartbeat,
  ) => {
    let resource = heartbeat->Component.toPulumiResource
    let runtime = RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(Heartbeat.componentType),
      ~handler=handler->Pulumi.Output.apply(handler => handler->RuntimeEnvironment.asEventHandler),
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
    connect(~runtime)
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

  let finish = _plugin => ()
}
