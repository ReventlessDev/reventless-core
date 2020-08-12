let name = "Plugin";

module Id: Reventless.Id.T = Reventless.Id.String;
[@decco]
type id = Id.t;

[@decco]
type name = string;

[@decco]
type version = string;

[@decco]
type dependencies = array(id);

[@decco]
type plugin = {
  name,
  version,
  dependencies,
};

[@decco]
type command =
  | Heartbeat
  | ConnectPlugin(plugin)
  | DisconnectPlugin;

[@decco]
type event =
  | UnknownPluginDetected
  | PluginConnected(plugin)
  | PluginDisconnected
  | PluginActivated
  | PluginDeactivated;

[@decco]
type error =
  | PluginDoesNotExist
  | PluginAlreadyExists;
