let name = "Plugin";

[@decco]
type id = string;
[@decco]
type timeout = int;

[@decco]
type command =
  | Heartbeat(timeout)
  | ConnectPlugin(PluginSpec.plugin)
  | DisconnectPlugin;

[@decco]
type event =
  | UnknownPluginDetected
  | PluginConnected(PluginSpec.plugin)
  | PluginDisconnected
  | PluginDeactivated
  | PluginActivated;

[@decco]
type callCommand =
  | ConfigAlarm(id, timeout);
