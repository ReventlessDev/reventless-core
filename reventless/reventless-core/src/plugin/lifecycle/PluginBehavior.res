@@reventless.behavior(PluginSpec)

open Reventless.Plugin

@schema
type state =
  | NotConnected
  | Detected
  | Connected(pluginDefinition)
  | Disconnected(pluginDefinition)
  | Inactive(pluginDefinition)
  // Deploy-superseded by a newer version. Revivable only by this version's
  // own Heartbeat (rollback / redeploy), never by admin Activate.
  | Retired(pluginDefinition)

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
    | Retire => Ok([Retired(pluginDefinition)]) // superseded by a newer version (UI already deregistered)
    | Heartbeat => Ok([]) // ignore — admin suspend is not heartbeat-revivable
    | ReportIncompatibility(incompatibleDef) => Ok([IncompatiblePluginDetected(incompatibleDef)])
    | Connect(_)
    | Disconnect
    | Deactivate =>
      Error(IsInactive)
    }
  | Retired(pluginDefinition) =>
    switch command {
    | Heartbeat =>
      // Revivable by its own heartbeat — a rollback / redeploy of this exact
      // version brings it back through Reconnected.
      Ok(
        Array.concat(
          [(Reconnected(pluginDefinition): event)],
          uiRegisterEvents(pluginDefinition.id, pluginDefinition.uiFragments),
        ),
      )
    | Retire => Ok([]) // idempotent — already retired
    | Disconnect => Ok([]) // tolerate a stray scheduled disconnect after retirement
    | ReportIncompatibility(incompatibleDef) => Ok([IncompatiblePluginDetected(incompatibleDef)])
    | Connect(_)
    | Activate
    | Deactivate =>
      Error(IsRetired) // admin cannot revive a superseded version
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
    | Retired(_) => Retired(pluginDefinition)
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
    | Retired(_) => Retired(pluginDefinition)
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
    | Retired(_) => Retired(pluginDefinition)
    | UnknownPluginDetected
    | Connected(_)
    | Reconnected(_)
    | Disconnected(_)
    | Deactivated(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  | Retired(pluginDefinition) =>
    switch event {
    | Reconnected(_) => Connected(pluginDefinition)
    | Retired(_) => state // idempotent re-entry (decide emits none)
    | IncompatiblePluginDetected(_)
    | UIFragmentRegistered(_)
    | UIFragmentUpdated(_)
    | UIFragmentDeregistered(_) => state
    | UnknownPluginDetected
    | Connected(_)
    | Disconnected(_)
    | Activated(_)
    | Deactivated(_) =>
      throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
    }
  }
