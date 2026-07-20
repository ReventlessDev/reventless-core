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

  let forPluginEventCollector = (
    ~handler,
    ~eventTopics: EventTopic.allOutputs,
    ~resources: array<ReventlessInfra.Adapter.resource>,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector,
  ) => {
    let resource = eventCollector->Component.toPulumiResource
    let name = resource.name->ComponentType.nameOpt(EventCollector.componentType)
    let opts = {Pulumi.ComponentResource.parent: resource}
    let runtime = RuntimeEnvironment.make(
      ~name,
      ~handler=handler->Pulumi.Output.apply(handler =>
        handler
        ->RuntimeEnvironment.asEffectHandler
        ->Runtime.runEffectHandler(
          ~extractCorrelationId=RuntimeEnvironment.extractCorrelationId,
          ~extractCausationId=RuntimeEnvironment.extractCausationId,
          ~comp=name,
        )
      ),
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

  let registerPluginName = (_: string) => ()

  let forDcbCommandTopic = (
    ~handler,
    ~connect,
    ~memorySize=1024,
    ~timeout=30,
    dcbCommandTopic,
  ) => {
    let resource = dcbCommandTopic->Component.toPulumiResource
    let name = resource.name->ComponentType.nameOpt(CommandTopic.componentType)
    let runtime = RuntimeEnvironment.make(
      ~name,
      ~handler=handler->Pulumi.Output.apply(handler =>
        handler
        ->RuntimeEnvironment.asEffectHandler
        ->Runtime.runEffectHandler(
          ~extractCorrelationId=RuntimeEnvironment.extractCorrelationId,
          ~extractCausationId=RuntimeEnvironment.extractCausationId,
          ~comp=name,
        )
      ),
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

  let finish = () => ()
}
