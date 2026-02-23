// In-memory aggregate builder.
// Wires in-memory adapters and delegates to Reventless.Aggregate_Builder.Make.

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
    Spec: ReventlessSpec.Aggregate.Spec,
    Behavior: Reventless.Behavior.T with module Spec := Spec,
    EventMappings: Reventless.EventMapper.Mappings with module Target := Spec,
  ) =>
    Reventless.Aggregate_Builder.Make(
      Spec,
      Behavior,
      EventMappings,
      RuntimeEnvironment,
      CommandGeneratorResolvers_InMemory,
      CommandTopicChannel,
      EventLogStorage_InMemory,
      EventTopicPublisher,
      EventCollectorChannel,
      AggregateRuntimeBuilder,
    )
}
