let name = "Plugin";

module Id = Id.String;

include ReventlessSpec.Plugin;

[@decco]
type command =
  | Heartbeat
  | ConnectPlugin(pluginDefinition, array(apiFragmentDescription))
  | DisconnectPlugin
  | ActivatePlugin
  | DeactivatePlugin;

[@decco]
type event =
  | UnknownPluginDetected
  | PluginConnected(pluginDefinition, array(apiFragmentDescription))
  | PluginReconnected(pluginDefinition, array(apiFragmentDescription))
  | PluginDisconnected(pluginDefinition, array(apiFragmentDescription))
  | PluginActivated(pluginDefinition, array(apiFragmentDescription))
  | PluginDeactivated(pluginDefinition, array(apiFragmentDescription));

[@decco]
type error =
  | PluginNotExisting
  | PluginIsConnected
  | PluginIsDisconnected
  | PluginIsInactive;
