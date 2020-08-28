let name = "Core.Plugin";

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
  | PluginReconnected
  | PluginDisconnected
  | PluginDeactivated
  | PluginActivated;

[@decco]
type callCommand =
  | ConfigAlarm(string, timeout)
  | ConnectPlugin(PluginSpec.plugin);
