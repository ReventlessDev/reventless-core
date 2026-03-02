// In-memory aggregate builder.
// Wires in-memory adapters and delegates to ReventlessCore.Aggregate_Builder.Make.

module Make = (Bus: InMemory_Bus.T) => {
  module RuntimeEnvironment = RuntimeEnvironment_InMemory
  module CommandTopicChannel = CommandTopicChannel_InMemory.Make(Bus)
  module EventTopicPublisher = EventTopicPublisher_InMemory.Make(Bus)
  module EventCollectorChannel = EventCollectorChannel_InMemory.Make(Bus)
  module AggregateRuntimeBuilder = AggregateRuntime_Builder_InMemory.Make(
    Bus,
    CommandTopicChannel,
    EventCollectorChannel,
  )

  module Make = (
    Spec: Reventless.Aggregate.Spec,
    Behavior: Reventless.Behavior.T with module Spec := Spec,
    EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
  ) => {
    include ReventlessCore.Aggregate_Builder.Make(
      Spec,
      Behavior,
      EventMappings,
      RuntimeEnvironment,
      CommandGeneratorResolvers_GraphQL,
      CommandTopicChannel,
      EventLogStorage_InMemory,
      EventTopicPublisher,
      EventCollectorChannel,
      AggregateRuntimeBuilder,
    )
    // Re-shadow `operations` with explicit spec return type so callers without
    // reventless in scope can still access ops.publishJsons (transparent alias).
    let operations: component => Pulumi.Output.t<ReventlessInfra.Aggregate.operations> = operations
  }
}
