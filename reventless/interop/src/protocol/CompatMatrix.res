// Protocol schema version declarations for built-in Reventless extension points.
//
// Each entry is the authoritative host-side version used when validating incoming
// ConnectPlugin handshakes. An extension plugin declares matching versions in its
// `pluginDefinition.extensionProtocols` array; the ConnectPlugin handler compares
// them with Compat.validateProtocol.
//
// Bump rules (see ExtensionPointProtocol.res for the full version policy):
//   commandVersion — bump when the corresponding @schema `command` type changes
//   eventVersion   — bump when the corresponding @schema `event` type changes
//
// ── Custom extension points ────────────────────────────────────────────────────
//
// There is no central registry for custom extension points. Application plugins
// define their own schemaVersions values co-located with their Spec modules
// (see `ExtensionPointProtocol.module type Versioned`) and pass them directly to
// Compat.validateProtocol inside their own ConnectPlugin handler.
//
// ── Built-in extension points ─────────────────────────────────────────────────

// Platform.Plugin — the single built-in extension point.
//
// command types (PluginExtensionPointSpec.command):
//   Heartbeat(timeout) | ConnectPlugin(pluginDefinition)
//   | DisconnectPlugin | ForwardCommand(forwardCommand)
//
// event types (PluginExtensionPointSpec.event):
//   UnknownPluginDetected | IncompatiblePlugin(pluginDefinition)
//   | PluginConnected(pluginDefinition) | PluginReconnected(pluginDefinition)
//   | PluginDisconnected(pluginDefinition) | PluginDeactivated(pluginDefinition)
//   | PluginActivated(pluginDefinition)
let platformPlugin: ExtensionPointProtocol.schemaVersions = {
  commandVersion: "1.0.0",
  eventVersion: "1.0.0",
}
