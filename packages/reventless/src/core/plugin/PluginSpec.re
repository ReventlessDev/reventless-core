let name = "Plugin";

module Id = Id.String;

include ReventlessSpec.Plugin;

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
  | PluginNotExisting
  | PluginIsConnected
  | PluginIsDisconnected
  | PluginIsInactive;
