let name = "Plugin"

module Id = ReventlessSpec.Id.String

open ReventlessSpec.Plugin

@schema
type command =
  | Heartbeat
  | Connect(pluginDefinition)
  | Disconnect
  | Activate
  | Deactivate

@schema
type event =
  | UnknownPluginDetected
  | Connected(pluginDefinition)
  | Reconnected(pluginDefinition)
  | Disconnected(pluginDefinition)
  | Activated(pluginDefinition)
  | Deactivated(pluginDefinition)

@schema
type error =
  | NotExisting
  | AlreadyConnected
  | IsDisconnected
  | IsInactive
