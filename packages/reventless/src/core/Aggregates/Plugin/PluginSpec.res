let name = "Plugin"

module Id = ReventlessSpec.Id.String

open ReventlessSpec.Plugin

@decco
type command =
  | Heartbeat
  | Connect(pluginDefinition)
  | Disconnect
  | Activate
  | Deactivate

@decco
type event =
  | UnknownPluginDetected
  | Connected(pluginDefinition)
  | Reconnected(pluginDefinition)
  | Disconnected(pluginDefinition)
  | Activated(pluginDefinition)
  | Deactivated(pluginDefinition)

@decco
type error =
  | NotExisting
  | AlreadyConnected
  | IsDisconnected
  | IsInactive
