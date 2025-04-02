module Mappings = {
  module type Mapping = ExtensionPointMapping.T
    with module ExtensionPoint := ReventlessSpec.PluginExtensionPointSpec

  let mappings: array<module(Mapping)> = [module(PluginExtensionPoint_Plugin.Mapping)]
}

module Make = (
  RuntimeBuilder: Reventless.Runtime_Builder.T,
  CommandTopicChannel: CommandTopic_Adapter.Channel with type runtimeParts = RuntimeBuilder.parts,
  EventTopicAdapter: EventTopic_Adapter.Publisher,
): ExtensionPoint.T => {
  include ExtensionPoint_Builder.Make(
    ReventlessSpec.PluginExtensionPointSpec,
    Mappings,
    RuntimeBuilder,
    CommandTopicChannel,
    EventTopicAdapter,
  )
}
