@@reventless.behavior

open Reventless.Plugin

// The current fragment for this plugin name plus its target API and the last recorded push
// outcome (kept only to dedupe at-least-once redelivery of RecordApiFragmentPush), or None
// when no fragment is registered.
type registryEntry = {
  fragment: apiSchemaFragment,
  apiTarget: apiTarget,
  lastPush: option<(bool, string, string)>, // (ok, message, at)
}
type state = option<registryEntry>

let initialState = None

let evolve = (state, event) =>
  switch event {
  | ApiFragmentRegistered({fragment, apiTarget}) => Some({fragment, apiTarget, lastPush: None})
  | ApiFragmentUpdated({newFragment, apiTarget}) =>
    Some({fragment: newFragment, apiTarget, lastPush: None})
  | ApiFragmentDeregistered(_) => None
  | ApiFragmentPushRecorded({ok, message, at}) =>
    state->Option.map(entry => {...entry, lastPush: Some((ok, message, at))})
  }

let decide = (state, command) =>
  switch command {
  | RegisterApiFragment({pluginId, fragment, apiTarget, at}) =>
    switch state {
    | None => Ok([ApiFragmentRegistered({pluginId, fragment, apiTarget, at})])
    // Idempotent: an unchanged re-registration (same fragment AND same target — e.g. a
    // redeploy carrying the same schema, or a version supersession that didn't change the
    // SDL) emits nothing. A target change with an identical fragment IS meaningful (the
    // fields move between the Domain and Platform APIs), so it is not a no-op.
    | Some({fragment: current, apiTarget: currentTarget})
      if current == fragment && currentTarget == apiTarget =>
      Ok([])
    | Some({fragment: current}) =>
      Ok([
        ApiFragmentUpdated({pluginId, previousFragment: current, newFragment: fragment, apiTarget, at}),
      ])
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
