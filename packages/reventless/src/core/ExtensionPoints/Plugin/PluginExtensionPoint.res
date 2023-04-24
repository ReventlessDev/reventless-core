module Mappings = {
  module type Mapping = ExtensionPointMapping.T
    with module ExtensionPoint := ReventlessSpec.PluginExtensionPointSpec

  let mappings: array<module(Mapping)> = [module(PluginExtensionPoint_Plugin.Mapping)]
}

module Make = (
  CommandTopicAdapter: CommandTopic.Adapter.Connector,
  EventTopicAdapter: EventTopic.Adapter.Publisher,
): ReventlessSpec.ExtensionPoint.T => {
  include ExtensionPoint.Make(
    ReventlessSpec.PluginExtensionPointSpec,
    Mappings,
    CommandTopicAdapter,
    EventTopicAdapter,
  )
}
