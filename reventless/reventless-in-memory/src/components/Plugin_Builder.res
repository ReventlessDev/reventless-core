// In-memory Plugin builder.
// Wraps ReventlessCore.Plugin_Builder.Make with in-memory adapters.
// Note: The Make functor result is sealed to Plugin.T in Platform.res,
// not here, because ReScript doesn't expose abstract types from `include`
// through functor return type annotations.

module Make = (Bus: InMemory_Bus.T, HooksConfig: ReventlessCore.Plugin_Helpers.HooksConfig) => {
  module EventCollectorChannel = EventCollectorChannel_InMemory.Make(Bus)
  module PluginRuntimeBuilder = PluginRuntime_Builder_InMemory.Make(Bus)
  module RemoteChannel = CommandTopicRemoteChannel_InMemory.Make(Bus)
  module QE = QueryEngine_InMemory.Make(Bus)

  include ReventlessCore.Plugin_Builder.Make(
    {
      let runtimeOps = InMemory_PluginSpec.runtimeOps
      let resourceNaming = InMemory_PluginSpec.resourceNaming
      let environment = InMemory_PluginSpec.environment
      let hooks = HooksConfig.hooks
    },
    {
      type api = unit
      type role = unit
    },
    GraphQL_InMemory_Adapter,
    RuntimeEnvironment_InMemory,
    EventCollectorChannel,
    QE,
    RemoteChannel,
    HeartbeatRunner_InMemory,
    PluginRuntimeBuilder,
    DcbEventLogStorage_InMemory.Make(Bus),
    EventTopicPublisher_InMemory.Make(Bus),
    CommandTopicChannel_InMemory.Make(Bus),
    CommandTopicChannel_InMemory.Make(Bus),
  )
}
