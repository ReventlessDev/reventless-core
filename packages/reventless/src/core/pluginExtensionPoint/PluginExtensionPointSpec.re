let name = "Core.Plugin";

[@decco]
type timeout = int; // in minutes

[@decco]
type forwardCommand = {
  extensionPointName: string,
  command: string,
};

[@decco]
type command =
  | Heartbeat(timeout)
  | ConnectPlugin(PluginSpec.pluginDefinition)
  | DisconnectPlugin
  | ForwardCommand(forwardCommand);

[@decco]
type event =
  | UnknownPluginDetected
  | PluginConnected(PluginSpec.pluginDefinition)
  | PluginReconnected(PluginSpec.pluginDefinition)
  | PluginDisconnected(PluginSpec.pluginDefinition)
  | PluginDeactivated(PluginSpec.pluginDefinition)
  | PluginActivated(PluginSpec.pluginDefinition);

[@decco]
type callCommand =
  | CreateDisconnectSchedule(string, timeout)
  | DeleteDisconnectSchedule(string)
  | DoConnectPlugin(PluginSpec.pluginDefinition)
  | DoDisconnectPlugin(PluginSpec.pluginDefinition)
  | ForwardCommand(forwardCommand);
