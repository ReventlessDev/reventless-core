// In-memory EventCollector runtime builder.
// Wires event collectors directly via the in-memory bus instead of Lambda + DynamoDB streams.

module Make = (
  Bus: LocalBus.T,
  EventCollectorChannel: ReventlessCore.EventCollector_Adapter.Channel
    with type runtimeParts = LocalRuntimeEnvironment.parts,
): (
  ReventlessCore.EventCollectorRuntime_Builder.T
    with type context = LocalRuntimeEnvironment.context
    and type runtimeParts = LocalRuntimeEnvironment.parts
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = LocalRuntimeEnvironment.context
  type runtimeParts = LocalRuntimeEnvironment.parts
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
    let runtime = LocalRuntimeEnvironment.make(
      ~name,
      ~handler=handler->Pulumi.Output.apply(h =>
        h->LocalRuntimeEnvironment.asEffectHandler->ReventlessCore.Runtime.runEffectHandler
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
