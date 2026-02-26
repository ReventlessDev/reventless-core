// In-memory EventCollector runtime builder.
// Wires event collectors directly via the in-memory bus instead of Lambda + DynamoDB streams.

module Make = (
  Bus: InMemory_Bus.T,
  EventCollectorChannel: ReventlessCore.EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment_InMemory.parts,
): (
  ReventlessCore.EventCollectorRuntime_Builder.T
    with type context = RuntimeEnvironment_InMemory.context
    and type runtimeParts = RuntimeEnvironment_InMemory.parts
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = RuntimeEnvironment_InMemory.context
  type runtimeParts = RuntimeEnvironment_InMemory.parts
  module EventCollectorChannel = EventCollectorChannel

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
