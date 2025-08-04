let name = "Core.Plugin"

include Plugin

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
  | PluginConnected(pluginDefinition)
  | PluginReconnected(pluginDefinition)
  | PluginDisconnected(pluginDefinition)
  | PluginDeactivated(pluginDefinition)
  | PluginActivated(pluginDefinition)

@schema
type callCommand =
  | CreateDisconnectSchedule(string, timeout)
  | DeleteDisconnectSchedule(string)
  | DoConnectPlugin(pluginDefinition)
  | DoDisconnectPlugin(pluginDefinition)
  | ForwardCommand(forwardCommand)
