let name = "Core.Plugin";

include Plugin;

[@decco]
type timeout = int; // in minutes

[@decco]
type forwardCommand = {
  extensionPointName: string,
  id: string,
  command: string,
};

[@decco]
type command =
  | Heartbeat(timeout)
  | ConnectPlugin(pluginDefinition, array(apiFragmentDescription))
  | DisconnectPlugin
  | ForwardCommand(forwardCommand);

[@decco]
type event =
  | UnknownPluginDetected
  | PluginConnected(pluginDefinition, array(apiFragmentDescription))
  | PluginReconnected(pluginDefinition, array(apiFragmentDescription))
  | PluginDisconnected(pluginDefinition, array(apiFragmentDescription))
  | PluginDeactivated(pluginDefinition, array(apiFragmentDescription))
  | PluginActivated(pluginDefinition, array(apiFragmentDescription));

[@decco]
type callCommand =
  | CreateDisconnectSchedule(string, timeout)
  | DeleteDisconnectSchedule(string)
  | DoConnectPlugin(pluginDefinition)
  | DoDisconnectPlugin(pluginDefinition)
  | ForwardCommand(forwardCommand);
