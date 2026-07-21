module Make = (
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
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
    ~handler: Pulumi.Output.t<CommandGenerator.effectEventHandler<context>>,
    ~connect,
    ~memorySize=1024,
    ~timeout=30,
    commandGenerator,
  ) => {
    let resource = commandGenerator->Component.toPulumiResource
    let name = resource.name->ComponentType.nameOpt(CommandGenerator.componentType)
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
          ~comp=name,
        )
      ),
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
    connect(~runtime)
  }
  let forCommandTopic = (
    ~handler: Pulumi.Output.t<
      Runtime.effectHandler<CommandTopicChannel.callbackEvent, context, unit, string>,
    >,
    ~connect,
    ~memorySize=1024,
    ~timeout=30,
    commandTopic,
  ) => {
    let resource = commandTopic->Component.toPulumiResource
    let name = resource.name->ComponentType.nameOpt(CommandTopic.componentType)
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
          ~comp=name,
        )
      ),
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
    connect(~runtime)
  }

  let forEventCollector = (
    ~handler: Pulumi.Output.t<
      Runtime.effectHandler<EventCollectorChannel.callbackEvent, context, unit, string>,
    >,
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
          ~extractSentTimestamp=RuntimeEnvironment.extractSentTimestamp,
          ~extractRetryCount=RuntimeEnvironment.extractRetryCount,
          ~comp=name,
        )
      ),
      ~memorySize,
      ~timeout,
      ~opts,
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
