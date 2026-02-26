let name = "Core.Plugin"

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

@schema
type directive =
  | CreateDisconnectSchedule(string, timeout)
  | DeleteDisconnectSchedule(string)
  | DoConnectPlugin(pluginDefinition)
  | DoDisconnectPlugin(pluginDefinition)
  | ForwardCommand(forwardCommand)
