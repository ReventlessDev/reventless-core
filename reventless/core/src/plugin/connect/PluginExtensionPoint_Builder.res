module PluginExtensionPointSpec = ReventlessInfra.PluginExtensionPointSpec

module type Spec = {
  let runtimeOps: PluginRuntimeOperations.operations
  let environment: string
  let updateApiSchema: option<Reventless.QueryEngine.operations => promise<unit>>
  let manageSubscriptions: option<
    (Reventless.Plugin.pluginDefinition, [#connect | #disconnect]) => promise<unit>,
  >
}

module Make = (
  Spec: Spec,
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventTopicAdapter: EventTopic_Adapter.Publisher,
  ExtensionPointRuntimeBuilder: ExtensionPointRuntime_Builder.T
    with module CommandTopicChannel := CommandTopicChannel,
  Defaults: ReventlessInfra.RuntimeDefaults.T,
): ExtensionPoint.T => {
  module PluginMappingInstance = PluginExtensionPoint_Plugin.Make(Spec)

  module Mappings = {
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T
      with module ExtensionPoint := PluginExtensionPointSpec

    let name = PluginMappingInstance.Mapping.delegateName
    let moduleUrl = PluginExtensionPointSpec.moduleUrl
    // The UI-fragment mapping routes RegisterUiFragment / (Disconnect →) DeregisterUiFragment to
    // the admin UiFragmentRegistry slice; the Plugin mapping keeps the lifecycle. Both run per
    // incoming command (ExtensionPoint_Callback fans commands through all mappings).
    let mappings: array<module(Mapping)> = [
      module(PluginMappingInstance.Mapping),
      module(PluginExtensionPoint_UiFragment.Mapping),
    ]
  }
  include ExtensionPoint_Builder.Make(
    PluginExtensionPointSpec,
    Mappings,
    RuntimeEnvironment,
    CommandTopicChannel,
    EventTopicAdapter,
    ExtensionPointRuntimeBuilder,
    Defaults,
  )
}
