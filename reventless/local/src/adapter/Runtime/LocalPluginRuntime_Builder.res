// In-memory PluginRuntime builder.
// Wraps PluginRuntime_Builder_Micro with LocalRuntimeEnvironment and LocalEventCollectorChannel.

module Make = (Bus: LocalBus.T) => {
  module ECChannel = LocalEventCollectorChannel.Make(Bus)

  include ReventlessCore.PluginRuntime_Builder_Micro.Make(
    LocalRuntimeEnvironment,
    ECChannel,
  )
}
