let name = "Core.Plugin"

include Plugin

@decco
type timeout = int // in minutes

@decco
type forwardCommand = {
  extensionPointName: string,
  id: string,
  command: string,
}

@decco
type command =
  | Heartbeat(timeout)
  | ConnectPlugin(pluginDefinition)
  | DisconnectPlugin
  | ForwardCommand(forwardCommand)

@decco
type event =
  | UnknownPluginDetected
  | PluginConnected(pluginDefinition)
  | PluginReconnected(pluginDefinition)
  | PluginDisconnected(pluginDefinition)
  | PluginDeactivated(pluginDefinition)
  | PluginActivated(pluginDefinition)

@decco
type callCommand =
  | CreateDisconnectSchedule(string, timeout)
  | DeleteDisconnectSchedule(string)
  | DoConnectPlugin(pluginDefinition)
  | DoDisconnectPlugin(pluginDefinition)
  | ForwardCommand(forwardCommand)
