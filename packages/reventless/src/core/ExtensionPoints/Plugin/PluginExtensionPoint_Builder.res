module Mappings = {
  module type Mapping = ExtensionPointMapping.T
    with module ExtensionPoint := ReventlessSpec.PluginExtensionPointSpec

  let mappings: array<module(Mapping)> = [module(PluginExtensionPoint_Plugin.Mapping)]
}

module Make = (
  RuntimeEnvironment: Reventless.Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventTopicAdapter: EventTopic_Adapter.Publisher,
): ExtensionPoint.T => {
  include ExtensionPoint_Builder.Make(
    ReventlessSpec.PluginExtensionPointSpec,
    Mappings,
    RuntimeEnvironment,
    CommandTopicChannel,
    EventTopicAdapter,
  )
}
