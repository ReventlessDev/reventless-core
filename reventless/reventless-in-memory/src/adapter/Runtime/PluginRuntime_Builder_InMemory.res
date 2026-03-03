// In-memory PluginRuntime builder.
// Wraps PluginRuntime_Builder_Micro with RuntimeEnvironment_InMemory and EventCollectorChannel_InMemory.

module Make = (Bus: InMemory_Bus.T) => {
  module ECChannel = EventCollectorChannel_InMemory.Make(Bus)

  include ReventlessCore.PluginRuntime_Builder_Micro.Make(
    RuntimeEnvironment_InMemory,
    ECChannel,
  )
}
