let name = "Core.Plugin";

[@decco]
type timeout = int; // in minutes

[@decco]
type command =
  | Heartbeat(timeout)
  | ConnectPlugin(PluginSpec.plugin)
  | DisconnectPlugin;

[@decco]
type event =
  | UnknownPluginDetected
  | PluginConnected(PluginSpec.plugin)
  | PluginReconnected
  | PluginDisconnected
  | PluginDeactivated
  | PluginActivated;

[@decco]
type callCommand =
  | CreateDisconnectSchedule(string, timeout)
  | DeleteDisconnectSchedule(string)
  | ConnectPlugin(PluginSpec.plugin);
