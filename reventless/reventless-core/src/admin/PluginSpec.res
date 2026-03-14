let name = "Plugin"

module Id = Reventless.Id.String

open Reventless.Plugin

@schema
type command =
  | Heartbeat
  | Connect(pluginDefinition)
  | Disconnect
  | Activate
  | Deactivate
  // Records a protocol-version incompatibility without changing plugin connection state.
  | ReportIncompatibility(pluginDefinition)

@schema
type event =
  | UnknownPluginDetected
  | Connected(pluginDefinition)
  | Reconnected(pluginDefinition)
  | Disconnected(pluginDefinition)
  | Activated(pluginDefinition)
  | Deactivated(pluginDefinition)
  // Emitted when ReportIncompatibility is processed; carries the connecting plugin definition.
  | IncompatiblePluginDetected(pluginDefinition)

@schema
type error =
  | NotExisting
  | AlreadyConnected
  | IsDisconnected
  | IsInactive
