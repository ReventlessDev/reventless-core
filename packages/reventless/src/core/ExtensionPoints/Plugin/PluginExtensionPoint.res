module Mappings = {
  module type Mapping = ExtensionPointMapping.T
    with module ExtensionPoint := ReventlessSpec.PluginExtensionPointSpec

  let mappings: array<module(Mapping)> = [module(PluginExtensionPoint_Plugin.Mapping)]
}

module Make = (
  CommandTopicChannel: CommandTopic_Adapter.Channel,
  EventTopicAdapter: EventTopic_Adapter.Publisher,
  RuntimeEnvironment: Reventless.Runtime.Environment,
): ExtensionPoint.T => {
  include ExtensionPoint.Make(
    ReventlessSpec.PluginExtensionPointSpec,
    Mappings,
    CommandTopicChannel,
    EventTopicAdapter,
    RuntimeEnvironment,
  )
}
