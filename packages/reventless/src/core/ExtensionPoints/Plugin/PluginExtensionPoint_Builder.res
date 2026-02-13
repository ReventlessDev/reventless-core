module type Spec = {
  let runtimeOps: ReventlessSpec.PluginRuntimeOperations.operations
  let environment: string
}

module Make = (
  Spec: Spec,
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventTopicAdapter: EventTopic_Adapter.Publisher,
  ExtensionPointRuntimeBuilder: ExtensionPointRuntime_Builder.T
    with module CommandTopicChannel := CommandTopicChannel,
): ExtensionPoint.T => {
  module PluginMappingInstance = PluginExtensionPoint_Plugin.Make(Spec)

  module Mappings = {
    module type Mapping = ExtensionPointMapping.T
      with module ExtensionPoint := ReventlessSpec.PluginExtensionPointSpec

    let mappings: array<module(Mapping)> = [module(PluginMappingInstance.Mapping)]
  }
  include ExtensionPoint_Builder.Make(
    ReventlessSpec.PluginExtensionPointSpec,
    Mappings,
    RuntimeEnvironment,
    CommandTopicChannel,
    EventTopicAdapter,
    ExtensionPointRuntimeBuilder,
  )
}
