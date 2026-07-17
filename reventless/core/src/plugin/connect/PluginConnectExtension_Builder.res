// Deploy-time Extension component for PluginConnectExtension. Pulls Pulumi via
// `include Extension_Builder.Make(...)`; layer-builder filters this file out of
// the Lambda layer (`**/*_Builder*.res.mjs` glob). The runtime-relevant
// mapping logic lives in PluginConnectExtension_Mapping.res so the
// EventCollector entry point can dynamic-import it at cold start.

module PluginExtensionPointSpec = ReventlessInfra.PluginExtensionPointSpec

module type Spec = PluginConnectExtension_Mapping.Spec

module Make = (Spec: Spec) => {
  include PluginConnectExtension_Mapping.Make(Spec)
  include Extension_Builder.Make(PluginExtensionPointSpec, ConnectPluginMappings)
}
