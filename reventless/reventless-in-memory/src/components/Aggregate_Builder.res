// In-memory aggregate builder.
// Wires in-memory adapters and delegates to ReventlessCore.Aggregate_Builder.Make.

let noHooks: ReventlessCore.Plugin_Helpers.platformHooks = {
  adminExtensionPoints: ref(Pulumi.Output.make(Dict.make())),
  scheduler: ref(None),
  api: ref(None),
  apiRole: ref(None),
}

// MakeWithHooks — full version used by the Platform (passes hook callbacks to core builder).
module MakeWithHooks = (
  Bus: InMemory_Bus.T,
  HooksConfig: ReventlessCore.Plugin_Helpers.HooksConfig,
) => {
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
      EventLogStorage_InMemory.Make(Bus),
      EventTopicPublisher,
      EventCollectorChannel,
      AggregateRuntimeBuilder,
      HooksConfig,
    )
    // Re-shadow `operations` with explicit spec return type so callers without
    // reventless in scope can still access ops.publishJsons (transparent alias).
    let operations: component => Pulumi.Output.t<ReventlessInfra.Aggregate.operations> = operations
  }
}

// Make — simple version for standalone tests and examples (no hook callbacks).
module Make = (Bus: InMemory_Bus.T) => {
  include MakeWithHooks(Bus, {let hooks = noHooks})
}
