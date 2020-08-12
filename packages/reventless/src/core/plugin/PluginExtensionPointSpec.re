let name = "Plugin";

module Id = Id.String;
[@decco]
type id = Id.t;

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

type error = unit;
