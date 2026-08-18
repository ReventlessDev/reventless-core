let name = "Platform.Plugin"

include Reventless.Plugin

@schema
type timeout = int // in minutes

@schema
type forwardCommand = {
  extensionPointName: string,
  id: string,
  command: string,
}

@schema
type command =
  | Heartbeat(timeout)
  | ConnectPlugin(pluginDefinition)
  | DisconnectPlugin
  | ForwardCommand(forwardCommand)
  // Registers this plugin's UI-fragment manifest with the admin UiFragmentRegistry slice.
  // Sent by the plugin's connect extension alongside ConnectPlugin (see
  // docs/plans/done/event-sourced-fragment-registries.md). Routed by the admin EP's UI-fragment
  // mapping to UiFragmentRegistry.RegisterUiFragment; DisconnectPlugin drives the matching
  // DeregisterUiFragment. Decoupling the manifest from the Plugin aggregate's lifecycle.
  | RegisterUiFragment(uiFragmentManifest)
  // Deploy-time re-detect: fired once by `deployPlugin` on every (re)deploy. Unlike
  // a keep-alive `Heartbeat`, this forces the connect handshake to run again for an
  // already-connected version so its current definition (e.g. a newly added `kind`,
  // updated uiFragments/protocols) is re-serialized onto the lifecycle row. Carries
  // the timeout so it also re-arms the disconnect schedule like a heartbeat.
  | RedetectPlugin(timeout)

@schema
type event =
  | UnknownPluginDetected
  // Emitted when a connecting plugin declared incompatible protocol versions.
  // The plugin is still connected; this event gives operators visibility.
  | IncompatiblePlugin(pluginDefinition)
  | PluginConnected(pluginDefinition)
  | PluginReconnected(pluginDefinition)
  | PluginDisconnected(pluginDefinition)
  | PluginDeactivated(pluginDefinition)
  | PluginActivated(pluginDefinition)
  | PluginRetired(pluginDefinition)

// Order is load-bearing: sury strands constructors declared after a run of two or
// more same-shaped ones, so union-carrying payloads must lead (DZakh/sury#392).
@schema
type directive =
  | DoConnectPlugin(pluginDefinition)
  | DoDisconnectPlugin(pluginDefinition)
  | ForwardCommand(forwardCommand)
  | CreateDisconnectSchedule(string, timeout)
  | DeleteDisconnectSchedule(string)

let moduleUrl: string = %raw(`import.meta.url`)
