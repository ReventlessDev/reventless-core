let name = "Plugin";

[@decco]
type command =
  | Heartbeat
  | RegisterPlugin
  | DisconnectPlugin;

[@decco]
type event =
  | UnknownPluginDetected
  | PluginRegistered
  | PluginDisconnected
  | PluginConnected
  | PluginDeacivated
  | PluginActivated;

[@decco]
type callCommand = unit;
