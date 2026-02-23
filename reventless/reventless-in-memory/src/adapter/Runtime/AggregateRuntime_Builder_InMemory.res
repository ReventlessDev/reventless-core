// In-memory aggregate runtime builder.
// Instead of creating Lambda functions and SQS/DynamoDB event source mappings,
// wires handlers directly via the in-memory bus.

module Make = (
  Bus: InMemory_Bus.T,
  CommandTopicChannel: Reventless.CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment_InMemory.parts,
  EventCollectorChannel: Reventless.EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment_InMemory.parts,
): (
  Reventless.AggregateRuntime_Builder.T
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
    ~handler as _,
    ~connect as _,
    ~memorySize as _=?,
    ~timeout as _=?,
    _commandGenerator,
  ) => () // No-op: no AppSync in-memory

  let forCommandTopic = (
    ~handler,
    ~connect,
    ~memorySize as _=?,
    ~timeout as _=?,
    commandTopic,
  ) => {
    let resource = commandTopic->Reventless.Component.toPulumiResource
    let runtime = RuntimeEnvironment_InMemory.make(
      ~name=resource.name->Reventless.ComponentType.nameOpt(Reventless.CommandTopic.componentType),
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
    let resource = eventCollector->Reventless.Component.toPulumiResource
    let name =
      resource.name->Reventless.ComponentType.nameOpt(Reventless.EventCollector.componentType)
    let opts = {Pulumi.ComponentResource.parent: resource}
    let runtime = RuntimeEnvironment_InMemory.make(
      ~name,
      ~handler=handler->Pulumi.Output.apply(h => h->RuntimeEnvironment_InMemory.asEventHandler),
    )
    let _connectResources = EventCollectorChannel.connect(
      ~name,
      ~channelSpecs=[
        {channel: eventCollector->Reventless.EventCollector_Adapter.channel, eventTopics, resources},
      ],
      ~runtime,
      ~opts,
    )
  }

  let finish = () => ()
}
