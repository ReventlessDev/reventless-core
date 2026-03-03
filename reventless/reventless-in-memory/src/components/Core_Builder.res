// In-memory Core builder.
// Wraps ReventlessCore.Core_Builder.Make with in-memory adapters.

module Make = (Bus: InMemory_Bus.T) => {
  module EventCollectorChannel = EventCollectorChannel_InMemory.Make(Bus)
  module QE = QueryEngine_InMemory.Make(Bus)

  include ReventlessCore.Core_Builder.Make(
    RuntimeEnvironment_InMemory,
    EventCollectorChannel,
    QE,
    ClonerRunner_InMemory,
    ReventlessCore.PluginRuntime_Builder_Micro.Make(RuntimeEnvironment_InMemory, EventCollectorChannel),
  )
}
