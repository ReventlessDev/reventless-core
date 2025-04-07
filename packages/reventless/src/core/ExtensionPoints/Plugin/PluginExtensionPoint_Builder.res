module Mappings = {
  module type Mapping = ExtensionPointMapping.T
    with module ExtensionPoint := ReventlessSpec.PluginExtensionPointSpec

  let mappings: array<module(Mapping)> = [module(PluginExtensionPoint_Plugin.Mapping)]
}

module Make = (
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventTopicAdapter: EventTopic_Adapter.Publisher,
  ExtensionPointRuntimeBuilder: ExtensionPointRuntime_Builder.T
    with module CommandTopicChannel := CommandTopicChannel,
): ExtensionPoint.T => {
  include ExtensionPoint_Builder.Make(
    ReventlessSpec.PluginExtensionPointSpec,
    Mappings,
    RuntimeEnvironment,
    CommandTopicChannel,
    EventTopicAdapter,
    ExtensionPointRuntimeBuilder,
  )
}
