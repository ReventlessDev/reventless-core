@@reventless.behavior

open Reventless.Plugin

// The current manifest for this plugin name, or None when no fragment is registered.
type state = option<uiFragmentManifest>

let initialState = None

let evolve = (_state, event) =>
  switch event {
  | UiFragmentRegistered({manifest}) => Some(manifest)
  | UiFragmentUpdated({newManifest}) => Some(newManifest)
  | UiFragmentDeregistered(_) => None
  }

let decide = (state, command) =>
  switch command {
  | RegisterUiFragment({pluginId, manifest, at}) =>
    switch state {
    | None => Ok([UiFragmentRegistered({pluginId, manifest, at})])
    // Idempotent: an unchanged re-registration (e.g. a redeploy carrying the same
    // manifest, or a reconnect) emits nothing.
    | Some(current) if current == manifest => Ok([])
    | Some(current) =>
      Ok([UiFragmentUpdated({pluginId, previousManifest: current, newManifest: manifest, at})])
    }
  | DeregisterUiFragment({pluginId}) =>
    switch state {
    | None => Ok([]) // idempotent — nothing registered
    | Some(_) => Ok([UiFragmentDeregistered({pluginId: pluginId})])
    }
  }
