module type Spec = {
  let runtimeOps: PluginRuntimeOperations.operations
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
    module type Mapping = ReventlessSpec.ExtensionPointMapping.T
      with module ExtensionPoint := PluginExtensionPointSpec

    let mappings: array<module(Mapping)> = [module(PluginMappingInstance.Mapping)]
  }
  include ExtensionPoint_Builder.Make(
    PluginExtensionPointSpec,
    Mappings,
    RuntimeEnvironment,
    CommandTopicChannel,
    EventTopicAdapter,
    ExtensionPointRuntimeBuilder,
  )
}
