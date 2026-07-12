@@reventless.behavior

open Reventless.Plugin

// The current fragment for this plugin name plus the last recorded push outcome (kept
// only to dedupe at-least-once redelivery of RecordApiFragmentPush), or None when no
// fragment is registered.
type registryEntry = {
  fragment: apiSchemaFragment,
  lastPush: option<(bool, string, string)>, // (ok, message, at)
}
type state = option<registryEntry>

let initialState = None

let evolve = (state, event) =>
  switch event {
  | ApiFragmentRegistered({fragment}) => Some({fragment, lastPush: None})
  | ApiFragmentUpdated({newFragment}) => Some({fragment: newFragment, lastPush: None})
  | ApiFragmentDeregistered(_) => None
  | ApiFragmentPushRecorded({ok, message, at}) =>
    state->Option.map(entry => {...entry, lastPush: Some((ok, message, at))})
  }

let decide = (state, command) =>
  switch command {
  | RegisterApiFragment({pluginId, fragment, at}) =>
    switch state {
    | None => Ok([ApiFragmentRegistered({pluginId, fragment, at})])
    // Idempotent: an unchanged re-registration (e.g. a redeploy carrying the same
    // fragment, or a version supersession with an unchanged schema) emits nothing.
    | Some({fragment: current}) if current == fragment => Ok([])
    | Some({fragment: current}) =>
      Ok([ApiFragmentUpdated({pluginId, previousFragment: current, newFragment: fragment, at})])
    }
  | DeregisterApiFragment({pluginId}) =>
    switch state {
    | None => Ok([]) // idempotent — nothing registered
    | Some(_) => Ok([ApiFragmentDeregistered({pluginId: pluginId})])
    }
  | RecordApiFragmentPush({pluginId, ok, message, at}) =>
    switch state {
    | None => Ok([]) // fragment deregistered in the meantime — nowhere to record
    // Idempotent: an at-least-once redelivery carries the identical payload.
    | Some({lastPush: Some((lastOk, lastMessage, lastAt))})
      if lastOk == ok && lastMessage == message && lastAt == at =>
      Ok([])
    | Some(_) => Ok([ApiFragmentPushRecorded({pluginId, ok, message, at})])
    }
  }
