// Second mapping on the admin PluginExtensionPoint, routing UI-fragment lifecycle to the
// admin UiFragmentRegistry StateChangeSlice (docs/plans/event-sourced-fragment-registries.md).
//
// The EP runtime fans every incoming command through ALL mappings and flattens the results
// (ExtensionPoint_Callback.mapIncomingCommands). This mapping's Delegate is the slice, so its
// PublishCommand encodes with the slice's commandSchema and routes to the slice's command
// topic via publishToAggregates["UiFragmentRegistry"] (registered by Platform_Admin's merge).
// The sibling PluginExtensionPoint_Plugin mapping keeps handling lifecycle for the Plugin
// aggregate; the two run side by side on the same EP.
//
// A StateChangeSlice Spec structurally satisfies Reventless.Aggregate.Spec (name, Id,
// command/event/error + schemas, commandSchema, commandAuthorization, moduleUrl), which is all
// ExtensionPointMapping.Make consumes from a Delegate.

open ReventlessInfra.ExtensionPointMapping

module PluginExtensionPointSpec = ReventlessInfra.PluginExtensionPointSpec

module UiFragmentMapping = {
  module ExtensionPoint = PluginExtensionPointSpec
  module Delegate = UiFragmentRegistry

  let moduleUrl: string = %raw(`import.meta.url`)

  // `id` is the EP transport id (`name@version`); the registry is keyed by bare plugin name,
  // so route on `Plugin.name(id)`. `at` carries the incoming command's producer time (the
  // StateViewSlice projection has no event meta).
  let mapIncomingCommand = (id, cmd, meta: Reventless.Message.meta) =>
    switch cmd {
    | PluginExtensionPointSpec.RegisterUiFragment(manifest) => [
        PublishCommand(
          Plugin.name(id),
          Delegate.RegisterUiFragment({
            pluginId: Plugin.name(id),
            manifest,
            at: meta.time,
          }),
        ),
      ]
    // Deregistration rides DisconnectPlugin, which the admin disconnect schedule also sends on
    // heartbeat timeout — so both graceful and timeout disconnects deregister the fragment.
    | DisconnectPlugin => [
        PublishCommand(Plugin.name(id), Delegate.DeregisterUiFragment({pluginId: Plugin.name(id)})),
      ]
    | Heartbeat(_) | ConnectPlugin(_) | RedetectPlugin(_) | ForwardCommand(_) => []
    }

  // This mapping never reflects slice events back through the EP.
  let mapOutgoingEvent = None
}

module Mapping = ReventlessInfra.ExtensionPointMapping.Make(UiFragmentMapping)
