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

  let forEventCollector = (~handler, ~connect, ~memorySize=1024, ~timeout=30, eventCollector) => {
    let resource = eventCollector->Component.toPulumiResource
    // let handler = handler->Pulumi.Output.apply(handler => (event, context) => {
    //   Js.log4("ReadModelRuntime_Builder_Micro.forEventCollector:", resource.name, event, context)
    //   handler(event, context)
    // })
    let runtime = RuntimeEnvironment.make(
      ~name=resource.name->Option.getOr("UnnamedReadModel"),
      ~handler=handler->Pulumi.Output.apply(handler => handler->RuntimeEnvironment.asEventHandler),
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )
    connect(~runtime)
  }
}
