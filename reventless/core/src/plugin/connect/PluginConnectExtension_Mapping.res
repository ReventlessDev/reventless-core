// Runtime-safe ConnectPlugin mapping — split out of PluginConnectExtension_Builder
// so the EventCollector Lambda entry point can dynamic-import it from the layer.
// PluginConnectExtension_Builder.res still pulls Pulumi via `include
// Extension_Builder.Make(...)` and is filtered out of the layer by the
// `**/*_Builder*.res.mjs` rimraf in DependencyBundler_PostProcess; this module
// contains only what runs in a Lambda.
//
// After Phase 3 of the plugin-eventcollector-runtime-rewire plans, cross-plugin
// SNS subscription management lives on the admin side (admin's EventCollector
// runs manageSubscriptions on every PluginConnected / Reconnected / Deactivated
// event). This mapping retains a single responsibility: the bootstrap step
// where a plugin emits a ConnectPlugin command to admin after admin posts an
// UnknownPluginDetected event referencing this plugin's id. No subscribe /
// unsubscribe directives are emitted any more.

@@reventless.spec

module PluginExtensionPointSpec = ReventlessInfra.PluginExtensionPointSpec
module ExtensionMapping = ReventlessInfra.ExtensionMapping

module type Spec = {
  let pluginDefinition: Reventless.Plugin.pluginDefinition
  // The plugin's UI-fragment manifest (no longer carried on pluginDefinition —
  // the UiFragmentRegistry slice owns fragment state; the definition keeps
  // lifecycle only). None for pure backend plugins.
  let uiFragments: option<Reventless.Plugin.uiFragmentManifest>
}

module Make = (Spec: Spec) => {
  module ConnectPluginMapping = ExtensionMapping.Make(
    {
      module ExtensionPoint = PluginExtensionPointSpec
      module Delegate = ReventlessInfra.ExtensionMapping.NoDelegate

      // Unused by ExtensionMapping.Make (it reads Delegate.moduleUrl, not the
      // arg's); present only to satisfy the input module type. The actually
      // dynamic-imported specifier is the file-level `moduleUrl` (@@reventless.spec
      // injected, move-safe) referenced from Plugin_Helpers.
      let moduleUrl = PluginExtensionPointSpec.moduleUrl

      let delegateModuleUrl = Delegate.moduleUrl

      let mapIncomingEvent: ReventlessInfra.ExtensionMapping.mapIncomingEvent<
        PluginExtensionPointSpec.event,
        Delegate.command,
        PluginExtensionPointSpec.command,
        PluginExtensionPointSpec.directive,
      > = (pluginId, event, _meta, _pluginDef, _queryEngine) => {
        let pluginDefinition = Spec.pluginDefinition
        let id = pluginDefinition.id

        switch event {
        // Answer the handshake, and — when this plugin ships a UI-fragment manifest — register
        // it with the admin UiFragmentRegistry slice in the same step (the admin EP's
        // UI-fragment mapping routes RegisterUiFragment to the slice). Nested switch (not
        // Array.concat) so the outer branch's expected type disambiguates the bare
        // PublishExtensionPointCommand constructor.
        | PluginExtensionPointSpec.UnknownPluginDetected if pluginId == id =>
          switch Spec.uiFragments {
          | Some(manifest) => [
              PublishExtensionPointCommand(
                id,
                PluginExtensionPointSpec.ConnectPlugin(pluginDefinition),
              ),
              PublishExtensionPointCommand(
                id,
                PluginExtensionPointSpec.RegisterUiFragment(manifest),
              ),
            ]
          | None => [
              PublishExtensionPointCommand(
                id,
                PluginExtensionPointSpec.ConnectPlugin(pluginDefinition),
              ),
            ]
          }
        // PluginConnected / PluginReconnected / PluginDeactivated for peer
        // plugins used to call DoConnectPlugin / DoDisconnectPlugin here so
        // each plugin's EC Lambda could subscribe / unsubscribe its own
        // queue to peer EP topics. Admin owns that work now
        // (manageSubscriptions in EventCollectorEntryPoint.mjs) — these
        // cases drop to no-ops.
        | _ => []
        }
      }

      let mapOutgoingEvent = None
    },
  )

  module ConnectPluginMappings = {
    module Spec = PluginExtensionPointSpec
    module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
    let name = "Connect"
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(ConnectPluginMapping)]
  }
}
