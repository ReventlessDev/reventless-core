@@reventless.spec("Plugin")

open Reventless.Plugin

@schema
type command =
  | @noApi Heartbeat
  | @noApi Connect(pluginDefinition)
  | @noApi Disconnect
  | Activate
  | Deactivate
  // Records a protocol-version incompatibility without changing plugin connection state.
  | @noApi ReportIncompatibility(pluginDefinition)
  // Emitted by the platform deploy hook when a newer plugin version
  // supersedes this one. Distinguishes deploy-driven retirement from
  // user-driven Deactivate in the EventLog and projection branches.
  | @noApi Retire

@schema
type uiFragmentRegisteredData = {pluginId: string, manifest: uiFragmentManifest}

@schema
type uiFragmentUpdatedData = {
  pluginId: string,
  previousManifest: uiFragmentManifest,
  newManifest: uiFragmentManifest,
}

@schema
type uiFragmentDeregisteredData = {pluginId: string}

@schema
type event =
  | UnknownPluginDetected
  | Connected(pluginDefinition)
  | Reconnected(pluginDefinition)
  | Disconnected(pluginDefinition)
  | Activated(pluginDefinition)
  | Deactivated(pluginDefinition)
  // Emitted on Retire — deploy-driven retirement of a superseded plugin version.
  | Retired(pluginDefinition)
  // Emitted when ReportIncompatibility is processed; carries the connecting plugin definition.
  | IncompatiblePluginDetected(pluginDefinition)
  // UI fragment lifecycle events — emitted alongside Connected/Reconnected/Disconnected/Deactivated
  // when the plugin's pluginDefinition.uiFragments is set.
  | UIFragmentRegistered(uiFragmentRegisteredData)
  | UIFragmentUpdated(uiFragmentUpdatedData)
  | UIFragmentDeregistered(uiFragmentDeregisteredData)

@schema
type error =
  | NotExisting
  | AlreadyConnected
  | IsDisconnected
  | IsInactive
