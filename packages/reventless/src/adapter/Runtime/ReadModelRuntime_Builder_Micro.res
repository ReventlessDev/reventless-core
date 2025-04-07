module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel,
): (
  ReadModelRuntime_Builder.T
    with type context = RuntimeEnvironment.context
    and type runtimeParts = RuntimeEnvironment.parts
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = RuntimeEnvironment.context
  type runtimeParts = RuntimeEnvironment.parts
  module EventCollectorChannel = EventCollectorChannel

  let forEventCollector = (~handler, ~memorySize=1024, ~timeout=30, eventCollector) => {
    let resource = eventCollector->Component.toPulumiResource
    RuntimeEnvironment.make(
      ~name=resource.name->ComponentType.nameOpt(EventCollector.componentType),
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
  }
}
