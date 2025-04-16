module Make = (
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
): (
  AggregateRuntime_Builder.T
    with type context = RuntimeEnvironment.context
    and type runtimeParts = RuntimeEnvironment.parts
    and module CommandTopicChannel = CommandTopicChannel
    and module EventCollectorChannel = EventCollectorChannel
) => {
  include AggregateRuntime_Builder_Common.Make(
    RuntimeEnvironment,
    CommandTopicChannel,
    EventCollectorChannel,
  )

  let finish = () => {
    let specs = aggregateRuntimeSpecs->Dict.valuesToArray
    let (parent, memorySize, timeout) = specs->Array.reduce((None, 0, 0), (
      (_, accMemorySize, accTimeout),
      {aggregate, memorySize, timeout},
    ) => {
      (aggregate.parent, Math.Int.max(accMemorySize, memorySize), Math.Int.max(accTimeout, timeout))
    })
    switch parent {
    | Some(parent) =>
      let runtime = RuntimeEnvironment.make(
        ~name=Aggregate.componentType->ComponentType.toString,
        ~handler=aggregateHandler("Single")->Pulumi.Output.make,
        ~memorySize,
        ~timeout,
        ~opts={Pulumi.ComponentResource.parent: parent},
      )
      let _ = specs->Array.map(({connects}) => {
        connects->Array.forEach(connect => connect(~runtime))
      })
    | None =>
      Js.log2(
        "AggregateRuntime_Builder_Single: No Runtime created because no parent found for Aggregate Runtime specs",
        aggregateRuntimeSpecs,
      )
    }
  }
}
