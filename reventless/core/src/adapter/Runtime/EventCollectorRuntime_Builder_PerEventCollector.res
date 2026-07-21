module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
): (
  EventCollectorRuntime_Builder.T
    with type context = RuntimeEnvironment.context
    and type runtimeParts = RuntimeEnvironment.parts
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = RuntimeEnvironment.context
  type runtimeParts = RuntimeEnvironment.parts
  module EventCollectorChannel = EventCollectorChannel

  let forEventCollector = (
    ~handler,
    ~eventTopics: EventTopic.allOutputs,
    ~resources: array<ReventlessInfra.Adapter.resource>,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector,
  ) => {
    let resource = eventCollector->Component.toPulumiResource
    let name = resource.name->ComponentType.nameOpt(EventCollector.componentType)
    // Same `comp` shape as the shared-runtime dispatchers, so a log filter reads the
    // same whichever deployment strategy hosts the collector.
    let comp = `EventCollector(${resource.name->Option.getOr("Unnamed")})`
    let opts = {Pulumi.ComponentResource.parent: resource}
    let runtime = RuntimeEnvironment.make(
      ~name,
      ~handler=handler->Pulumi.Output.apply(handler =>
        handler
        ->RuntimeEnvironment.asEffectHandler
        ->Runtime.runEffectHandler(
          ~extractCorrelationId=RuntimeEnvironment.extractCorrelationId,
          ~extractCausationId=RuntimeEnvironment.extractCausationId,
          ~extractSentTimestamp=RuntimeEnvironment.extractSentTimestamp,
          ~extractRetryCount=RuntimeEnvironment.extractRetryCount,
          ~comp,
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

  let finish = () => ()
}
