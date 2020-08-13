let name = "Plugin";

module Id: Reventless.Id.T = Reventless.Id.String;
[@decco]
type id = Id.t;

[@decco]
type name = string;

[@decco]
type version = string;

[@decco]
type extensionPoint = {
  id: string,
  commandTopic: string,
  eventTopic: string,
};

[@decco]
type extensionPoints = array(extensionPoint);

[@decco]
type extension = {
  id: string,
  commandTopic: string,
  eventTopic: string,
};

[@decco]
type extensions = array(extension);

[@decco]
type plugin = {
  name,
  version,
  extensionPoints: array(extensionPoint),
  extensions: array(extension),
};

[@decco]
type command =
  | Heartbeat
  | ConnectPlugin(plugin)
  | DisconnectPlugin
  | ActivatePlugin
  | DeactivatePlugin;

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
