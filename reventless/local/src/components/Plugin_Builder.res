// In-memory Plugin builder.
// Wraps ReventlessCore.Plugin_Builder.Make with in-memory adapters.
// Note: The Make functor result is sealed to Plugin.T in Platform.res,
// not here, because ReScript doesn't expose abstract types from `include`
// through functor return type annotations.

module Make = (Bus: LocalBus.T, HooksConfig: ReventlessCore.Plugin_Helpers.HooksConfig) => {
  module EventCollectorChannel = LocalEventCollectorChannel.Make(Bus)
  module PluginRuntimeBuilder = LocalPluginRuntime_Builder.Make(Bus)
  module RemoteChannel = LocalCommandTopicRemoteChannel.Make(Bus)
  module QE = LocalQueryEngine.Make(Bus)

  include ReventlessCore.Plugin_Builder.Make(
    {
      let runtimeOps = LocalPluginSpec.runtimeOps
      let resourceNaming = LocalPluginSpec.resourceNaming
      let environment = LocalPluginSpec.environment
      let platformName = LocalPluginSpec.platformName
      let hooks = HooksConfig.hooks
    },
    {
      type api = unit
      type role = unit
    },
    LocalGraphQL_Adapter,
    LocalRuntimeEnvironment,
    EventCollectorChannel,
    QE,
    RemoteChannel,
    LocalHeartbeatRunner,
    PluginRuntimeBuilder,
    LocalDcbEventLogStorage.Make(Bus),
    LocalEventTopicPublisher.Make(Bus),
    LocalCommandTopicChannel.Make(Bus),
    LocalCommandTopicChannel.Make(Bus),
  )
}
