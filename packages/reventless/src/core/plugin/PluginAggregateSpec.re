let name = "Plugin";

module Id: Id.T = Id.String;
[@decco]
type id = Id.t;

[@decco]
type command =
  | ConnectPlugin
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
type error =
  | PluginDoesNotExist;
