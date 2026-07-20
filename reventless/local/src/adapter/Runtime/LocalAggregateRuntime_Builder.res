// In-memory aggregate runtime builder.
// Instead of creating Lambda functions and SQS/DynamoDB event source mappings,
// wires handlers directly via the in-memory bus.

module Make = (
  Bus: LocalBus.T,
  CommandTopicChannel: ReventlessCore.CommandTopic_Adapter.Channel
    with type runtimeParts = LocalRuntimeEnvironment.parts,
  EventCollectorChannel: ReventlessCore.EventCollector_Adapter.Channel
    with type runtimeParts = LocalRuntimeEnvironment.parts,
): (
  ReventlessCore.AggregateRuntime_Builder.T
    with type context = LocalRuntimeEnvironment.context
    and type runtimeParts = LocalRuntimeEnvironment.parts
    and module CommandTopicChannel = CommandTopicChannel
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = LocalRuntimeEnvironment.context
  type runtimeParts = LocalRuntimeEnvironment.parts
  module CommandTopicChannel = CommandTopicChannel
  module EventCollectorChannel = EventCollectorChannel

  let forCommandGenerator = (
    ~handler,
    ~connect,
    ~memorySize as _=?,
    ~timeout as _=?,
    commandGenerator,
  ) => {
    // Call connect(~runtime) so CommandGeneratorResolvers_GraphQL.make registers SDL+resolvers.
    // The runtime's handlerRef is unused by the GraphQL resolver path, but we create a proper
    // runtime so the type is satisfied and future callers that need handlerRef will work.
    let resource = commandGenerator->ReventlessCore.Component.toPulumiResource
    let name =
      resource.name->ReventlessCore.ComponentType.nameOpt(ReventlessCore.CommandGenerator.componentType)
    let runtime = LocalRuntimeEnvironment.make(
      ~name,
      ~handler=handler->Pulumi.Output.apply(h =>
        h
        ->LocalRuntimeEnvironment.asEffectHandler
        ->ReventlessCore.Runtime.runEffectHandler(
          ~extractCorrelationId=LocalRuntimeEnvironment.extractCorrelationId,
          ~extractCausationId=LocalRuntimeEnvironment.extractCausationId,
          ~comp=name,
        )
      ),
    )
    connect(~runtime)
  }

  let forCommandTopic = (
    ~handler,
    ~connect,
    ~memorySize as _=?,
    ~timeout as _=?,
    commandTopic,
  ) => {
    let resource = commandTopic->ReventlessCore.Component.toPulumiResource
    let name =
      resource.name->ReventlessCore.ComponentType.nameOpt(ReventlessCore.CommandTopic.componentType)
    let runtime = LocalRuntimeEnvironment.make(
      ~name,
      ~handler=handler->Pulumi.Output.apply(h =>
        h
        ->LocalRuntimeEnvironment.asEffectHandler
        ->ReventlessCore.Runtime.runEffectHandler(
          ~extractCorrelationId=LocalRuntimeEnvironment.extractCorrelationId,
          ~extractCausationId=LocalRuntimeEnvironment.extractCausationId,
          ~comp=name,
        )
      ),
    )
    connect(~runtime)
  }

  let forEventCollector = (
    ~handler,
    ~eventTopics,
    ~resources,
    ~memorySize as _=?,
    ~timeout as _=?,
    eventCollector,
  ) => {
    let resource = eventCollector->ReventlessCore.Component.toPulumiResource
    let name =
      resource.name->ReventlessCore.ComponentType.nameOpt(ReventlessCore.EventCollector.componentType)
    let opts = {Pulumi.ComponentResource.parent: resource}
    let runtime = LocalRuntimeEnvironment.make(
      ~name,
      ~handler=handler->Pulumi.Output.apply(h =>
        h
        ->LocalRuntimeEnvironment.asEffectHandler
        ->ReventlessCore.Runtime.runEffectHandler(
          ~extractCorrelationId=LocalRuntimeEnvironment.extractCorrelationId,
          ~extractCausationId=LocalRuntimeEnvironment.extractCausationId,
          ~comp=name,
        )
      ),
    )
    let _connectResources = EventCollectorChannel.connect(
      ~name,
      ~channelSpecs=[
        {channel: eventCollector->ReventlessCore.EventCollector_Adapter.channel, eventTopics, resources},
      ],
      ~runtime,
      ~opts,
    )
  }

  let finish = () => ()
}
