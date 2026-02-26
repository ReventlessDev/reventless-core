// In-memory aggregate runtime builder.
// Instead of creating Lambda functions and SQS/DynamoDB event source mappings,
// wires handlers directly via the in-memory bus.

module Make = (
  Bus: InMemory_Bus.T,
  CommandTopicChannel: ReventlessCore.CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment_InMemory.parts,
  EventCollectorChannel: ReventlessCore.EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment_InMemory.parts,
): (
  ReventlessCore.AggregateRuntime_Builder.T
    with type context = RuntimeEnvironment_InMemory.context
    and type runtimeParts = RuntimeEnvironment_InMemory.parts
    and module CommandTopicChannel = CommandTopicChannel
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = RuntimeEnvironment_InMemory.context
  type runtimeParts = RuntimeEnvironment_InMemory.parts
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
    let runtime = RuntimeEnvironment_InMemory.make(
      ~name=resource.name->ReventlessCore.ComponentType.nameOpt(
        ReventlessCore.CommandGenerator.componentType,
      ),
      ~handler=handler->Pulumi.Output.apply(h => h->RuntimeEnvironment_InMemory.asEventHandler),
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
    let runtime = RuntimeEnvironment_InMemory.make(
      ~name=resource.name->ReventlessCore.ComponentType.nameOpt(ReventlessCore.CommandTopic.componentType),
      ~handler=handler->Pulumi.Output.apply(h => h->RuntimeEnvironment_InMemory.asEventHandler),
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
    let runtime = RuntimeEnvironment_InMemory.make(
      ~name,
      ~handler=handler->Pulumi.Output.apply(h => h->RuntimeEnvironment_InMemory.asEventHandler),
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
