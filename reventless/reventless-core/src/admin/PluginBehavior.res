@@reventless.behavior(PluginSpec)

open Reventless.Plugin

@schema
type state =
  | NotConnected
  | Detected
  | Connected(pluginDefinition)
  | Disconnected(pluginDefinition)
  | Inactive(pluginDefinition)

let initialState = NotConnected

let atomicCounter = None

let uiRegisterEvents = (pluginId, manifest) =>
  switch manifest {
  | None => []
  | Some(manifest) => [(UIFragmentRegistered({pluginId: pluginId, manifest: manifest}): event)]
  }

let uiDeregisterEvents = (pluginId, manifest) =>
  switch manifest {
  | None => []
  | Some(_) => [(UIFragmentDeregistered({pluginId: pluginId}): event)]
  }

let decide = (state, command) =>
  switch state {
  | NotConnected =>
    switch command {
    | Heartbeat => Ok([UnknownPluginDetected])
    | Connect(_)
    | Disconnect
    | Activate
    | Deactivate
    | Retire
    | ReportIncompatibility(_) =>
      Error(NotExisting)
    }
  | Detected =>
    switch command {
    | Connect(pluginDefinition) =>
      Ok(
        Array.concat(
          [(Connected(pluginDefinition): event)],
          uiRegisterEvents(pluginDefinition.id, pluginDefinition.uiFragments),
        ),
      )
    | Heartbeat => Ok([UnknownPluginDetected])
    | ReportIncompatibility(pluginDefinition) => Ok([IncompatiblePluginDetected(pluginDefinition)])
    | Disconnect
    | Activate
    | Deactivate
    | Retire => Ok([])
    }
  | Connected(pluginDefinition) =>
    switch command {
    | Disconnect =>
      Ok(
        Array.concat(
          [(Disconnected(pluginDefinition): event)],
          uiDeregisterEvents(pluginDefinition.id, pluginDefinition.uiFragments),
        ),
      )
    | Deactivate =>
      Ok(
        Array.concat(
          [(Deactivated(pluginDefinition): event)],
          uiDeregisterEvents(pluginDefinition.id, pluginDefinition.uiFragments),
        ),
      )
    | Retire =>
      Ok(
        Array.concat(
          [(Retired(pluginDefinition): event)],
          uiDeregisterEvents(pluginDefinition.id, pluginDefinition.uiFragments),
        ),
      )
    | Heartbeat => Ok([]) // ignore
    | ReportIncompatibility(incompatibleDef) => Ok([IncompatiblePluginDetected(incompatibleDef)])
    | Connect(_)
    | Activate =>
      Error(AlreadyConnected)
    }
  | Disconnected(pluginDefinition) =>
    switch command {
    | Heartbeat =>
      Ok(
        Array.concat(
          [(Reconnected(pluginDefinition): event)],
          uiRegisterEvents(pluginDefinition.id, pluginDefinition.uiFragments),
        ),
      )
    | Deactivate => Ok([Deactivated(pluginDefinition)]) // already deregistered when disconnected
    | Retire => Ok([Retired(pluginDefinition)]) // already deregistered when disconnected
    | ReportIncompatibility(incompatibleDef) => Ok([IncompatiblePluginDetected(incompatibleDef)])
    | Connect(_)
    | Disconnect
    | Activate =>
      Error(IsDisconnected)
    }
  | Inactive(pluginDefinition) =>
    switch command {
    | Activate =>
      Ok(
        Array.concat(
          [(Activated(pluginDefinition): event)],
          uiRegisterEvents(pluginDefinition.id, pluginDefinition.uiFragments),
        ),
      )
    | Retire => Ok([]) // idempotent — already inactive
    | Heartbeat => Ok([]) // ignore
    | ReportIncompatibility(incompatibleDef) => Ok([IncompatiblePluginDetected(incompatibleDef)])
    | Connect(_)
    | Disconnect
    | Deactivate =>
      Error(IsInactive)
    }
  }

let evolve = (state: state, event) =>
  switch state {
  | NotConnected =>
    switch event {
    | UnknownPluginDetected => Detected
    | Connected(pluginDefinition) => Connected(pluginDefinition)
    | IncompatiblePluginDetected(_)
    | UIFragmentRegistered(_)
    | UIFragmentUpdated(_)
    | UIFragmentDeregistered(_) => state
    | Reconnected(_)
    | Disconnected(_)
    | Activated(_)
    | Deactivated(_)
    | Retired(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Detected =>
    switch event {
    | UnknownPluginDetected => state
    | Connected(pluginDefinition) => Connected(pluginDefinition)
    | IncompatiblePluginDetected(_)
    | UIFragmentRegistered(_)
    | UIFragmentUpdated(_)
    | UIFragmentDeregistered(_) => state
    | Reconnected(_)
    | Disconnected(_)
    | Activated(_)
    | Deactivated(_)
    | Retired(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Connected(pluginDefinition) =>
    switch event {
    | Disconnected(_) => Disconnected(pluginDefinition)
    | Deactivated(_) => Inactive(pluginDefinition)
    | Retired(_) => Inactive(pluginDefinition)
    | IncompatiblePluginDetected(_)
    | UIFragmentRegistered(_)
    | UIFragmentUpdated(_)
    | UIFragmentDeregistered(_) => state
    | UnknownPluginDetected
    | Connected(_)
    | Reconnected(_)
    | Activated(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Disconnected(pluginDefinition) =>
    switch event {
    | Reconnected(_) => Connected(pluginDefinition)
    | Deactivated(_) => Inactive(pluginDefinition)
    | Retired(_) => Inactive(pluginDefinition)
    | IncompatiblePluginDetected(_)
    | UIFragmentRegistered(_)
    | UIFragmentUpdated(_)
    | UIFragmentDeregistered(_) => state
    | UnknownPluginDetected
    | Connected(_)
    | Disconnected(_)
    | Activated(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Inactive(pluginDefinition) =>
    switch event {
    | Activated(_) => Disconnected(pluginDefinition)
    | IncompatiblePluginDetected(_)
    | UIFragmentRegistered(_)
    | UIFragmentUpdated(_)
    | UIFragmentDeregistered(_) => state
    | UnknownPluginDetected
    | Connected(_)
    | Reconnected(_)
    | Disconnected(_)
    | Deactivated(_)
    | Retired(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  }
