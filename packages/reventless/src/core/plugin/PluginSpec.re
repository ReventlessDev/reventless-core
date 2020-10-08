let name = "Plugin";

module Id = Id.String;

[@decco]
type name = string;
[@decco]
type version = string;

[@decco]
type extensionPoint = {
  name: string,
  commandTopic: string,
  eventTopic: string,
};

[@decco]
type extension = {
  name: string,
  extensionPointName: string,
};

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
  | PluginReconnected
  | PluginDisconnected
  | PluginActivated
  | PluginDeactivated;

[@decco]
type error =
  | PluginDoesNotExist
  | PluginAlreadyExists;
