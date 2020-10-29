let name = "Plugin";

module Id = Id.String;

[@decco]
type name = string;
[@decco]
type version = string;

[@decco]
type extensionPointDefinition = {
  name: string,
  commandTopic: string,
  eventTopic: string,
};

[@decco]
type extensionDefinition = {
  name: string,
  extensionPointName: string,
};

[@decco]
type pluginDefinition = {
  id: string,
  name,
  version,
  extensionPoints: array(extensionPointDefinition),
  extensions: array(extensionDefinition),
  eventCollector: string,
};

[@decco]
type command =
  | Heartbeat
  | ConnectPlugin(pluginDefinition)
  | DisconnectPlugin
  | ActivatePlugin
  | DeactivatePlugin;

[@decco]
type event =
  | UnknownPluginDetected
  | PluginConnected(pluginDefinition)
  | PluginReconnected(pluginDefinition)
  | PluginDisconnected(pluginDefinition)
  | PluginActivated(pluginDefinition)
  | PluginDeactivated(pluginDefinition);

[@decco]
type error =
  | PluginDoesNotExist
  | PluginAlreadyExists;
