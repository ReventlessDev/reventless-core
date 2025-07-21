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

  let finished = ref(false)

  let finish = () =>
    if !finished.contents {
      let _ =
        runtimeSpecs
        ->Dict.toArray
        ->Array.map(((
          aggregateName,
          {aggregate, connects, eventCollectorChannelSpec, memorySize, timeout},
        )) => {
          let opts = {Pulumi.ComponentResource.parent: aggregate}
          let runtime = RuntimeEnvironment.make(
            ~name=aggregateName->ComponentType.name(Aggregate.componentType),
            ~handler=aggregateHandler(aggregateName)->Pulumi.Output.make,
            ~memorySize,
            ~timeout,
            ~opts,
          )
          connects->Array.forEach(connect => connect(~runtime))
          let _connectResources =
            eventCollectorChannelSpec->Option.map(channelSpec =>
              EventCollectorChannel.connect(
                ~name="AllReadModels",
                ~channelSpecs=[channelSpec],
                ~runtime,
                ~opts,
              )
            )
        })
      finished := true
    }
}
