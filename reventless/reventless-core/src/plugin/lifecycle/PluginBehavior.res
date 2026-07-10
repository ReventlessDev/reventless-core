@@reventless.behavior(PluginSpec)

open Reventless.Plugin

// Per-version status the aggregate tracks. `Superseded` is NOT here: a version
// that is live (Connected) but not `current` is "superseded" — that label is
// derived on the read side (Connected && version != current), so the aggregate
// stays minimal and `current` is always recomputable as "highest Connected".
@schema
type versionStatus =
  | Connected
  | Disconnected
  | Inactive
  | Retired

@schema
type knownVersion = {
  definition: pluginDefinition,
  status: versionStatus,
}

// Name-keyed state: every version this plugin name has ever connected, plus the
// pointer to the currently-active version. `current` is derived (highest
// Connected) — never compared against wall-clock time, so replay is deterministic.
@schema
type state = {
  current: option<version>,
  known: dict<knownVersion>,
}

let initialState = {current: None, known: Dict.make()}

// The @@reventless.behavior snapshot injection is gated to Aggregate/ folders;
// this framework-internal behavior lives under plugin/lifecycle, so the
// Behavior.T field is satisfied manually. The admin Plugin aggregate's history
// is short (lifecycle transitions), so persisted snapshots would buy nothing.
let snapshot = None

let atomicCounter = None

let uiRegisterEvents = (pluginId, manifest) =>
  switch manifest {
  | None => []
  | Some(manifest) => [(UIFragmentRegistered({pluginId, manifest}): event)]
  }

let uiDeregisterEvents = (pluginId, manifest) =>
  switch manifest {
  | None => []
  | Some(_) => [(UIFragmentDeregistered({pluginId: pluginId}): event)]
  }

// Highest version with status Connected, or None.
let highestConnected = (known: dict<knownVersion>): option<version> =>
  known
  ->Dict.toArray
  ->Array.reduce(None, (acc, (v, kv)) =>
    switch kv.status {
    | Connected =>
      switch acc {
      | None => Some(v)
      | Some(cur) => Plugin.compareVersions(v, cur) > 0 ? Some(v) : acc
      }
    | Disconnected | Inactive | Retired => acc
    }
  )

// Highest Connected version other than `exclude`.
let highestConnectedExcluding = (known: dict<knownVersion>, exclude: version): option<
  version,
> =>
  known
  ->Dict.toArray
  ->Array.reduce(None, (acc, (v, kv)) =>
    if v == exclude {
      acc
    } else {
      switch kv.status {
      | Connected =>
        switch acc {
        | None => Some(v)
        | Some(cur) => Plugin.compareVersions(v, cur) > 0 ? Some(v) : acc
        }
      | Disconnected | Inactive | Retired => acc
      }
    }
  )

// Which version is current after `v` becomes Connected.
let currentAfterConnect = (known, v) =>
  switch highestConnectedExcluding(known, v) {
  | None => v
  | Some(h) => Plugin.compareVersions(v, h) >= 0 ? v : h
  }

// Events emitted when `v` (with `def`) becomes Connected: the VersionConnected +
// UI register, plus a VersionSuperseded record when `v` takes over from a
// different current version.
let connectEvents = (state: state, v: version, def: pluginDefinition): array<event> => {
  let base = Array.concat([VersionConnected(def)], uiRegisterEvents(def.id, def.uiFragments))
  let supersede = if currentAfterConnect(state.known, v) == v {
    switch state.current {
    | Some(c) if c != v =>
      switch state.known->Dict.get(c) {
      | Some({definition: defC}) => [
          VersionSuperseded({
            supersededVersion: c,
            supersededDefinition: defC,
            newVersion: v,
            newDefinition: def,
          }),
        ]
      | None => []
      }
    | _ => []
    }
  } else {
    []
  }
  Array.concat(base, supersede)
}

// VersionPromoted record when the current version `v` leaves Connected and a
// lower still-Connected version is promoted (rollback). Empty otherwise.
let promoteEvents = (state: state, v: version): array<event> =>
  if state.current == Some(v) {
    switch highestConnectedExcluding(state.known, v) {
    | Some(w) =>
      switch state.known->Dict.get(w) {
      | Some({definition: defW}) => [VersionPromoted(defW)]
      | None => []
      }
    | None => []
    }
  } else {
    []
  }

let decide = (state, command) =>
  switch command {
  | Heartbeat(v) =>
    switch state.known->Dict.get(v) {
    | None => Ok([VersionDetected(v)]) // unknown version → trigger the connect handshake
    | Some({status: Connected}) => Ok([]) // keep-alive
    | Some({status: Disconnected, definition}) => Ok(connectEvents(state, v, definition)) // reconnect
    | Some({status: Inactive | Retired}) => Ok([]) // not heartbeat-revivable (admin only)
    }
  | Redetect(v) =>
    // Deploy-time re-detect: unlike Heartbeat, a *connected* version re-runs the
    // handshake (VersionDetected → ConnectPlugin → Connect) so the plugin re-answers
    // with its current definition and Connect below refreshes the stored def. Unknown
    // and disconnected versions detect exactly as a heartbeat would; archived versions
    // stay admin-only.
    switch state.known->Dict.get(v) {
    | Some({status: Inactive | Retired}) => Ok([]) // archived — not re-detect-revivable
    | None | Some({status: Connected | Disconnected}) => Ok([VersionDetected(v)])
    }
  | Connect(def) =>
    let v = def.version
    switch state.known->Dict.get(v) {
    // Idempotent when the definition is unchanged; when a redeploy carries a changed
    // definition (e.g. a newly added `kind`, updated uiFragments/protocols) re-emit
    // VersionConnected to overwrite the stored def and re-project the row. The version
    // is already current, so connectEvents' supersede stays empty — a bare refresh.
    | Some({status: Connected, definition}) => definition == def ? Ok([]) : Ok([VersionConnected(def)])
    | _ => Ok(connectEvents(state, v, def))
    }
  | Disconnect(v) =>
    switch state.known->Dict.get(v) {
    | Some({status: Connected, definition}) =>
      Ok(
        Array.concat(
          Array.concat(
            [VersionDisconnected(definition)],
            uiDeregisterEvents(definition.id, definition.uiFragments),
          ),
          promoteEvents(state, v),
        ),
      )
    | _ => Ok([]) // not connected / unknown → tolerate stray disconnect
    }
  | Activate(v) =>
    switch state.known->Dict.get(v) {
    | Some({status: Inactive | Retired, definition}) =>
      let base = Array.concat(
        [VersionActivated(definition)],
        uiRegisterEvents(definition.id, definition.uiFragments),
      )
      let supersede = if currentAfterConnect(state.known, v) == v {
        switch state.current {
        | Some(c) if c != v =>
          switch state.known->Dict.get(c) {
          | Some({definition: defC}) => [
              VersionSuperseded({
                supersededVersion: c,
                supersededDefinition: defC,
                newVersion: v,
                newDefinition: definition,
              }),
            ]
          | None => []
          }
        | _ => []
        }
      } else {
        []
      }
      Ok(Array.concat(base, supersede))
    | Some({status: Connected}) => Ok([]) // idempotent
    | Some({status: Disconnected}) => Error(IsDisconnected)
    | None => Error(UnknownVersion)
    }
  | Deactivate(v) =>
    switch state.known->Dict.get(v) {
    | Some({status: Connected | Disconnected, definition}) =>
      Ok(
        Array.concat(
          Array.concat(
            [VersionDeactivated(definition)],
            uiDeregisterEvents(definition.id, definition.uiFragments),
          ),
          promoteEvents(state, v),
        ),
      )
    | Some({status: Inactive | Retired}) => Ok([]) // idempotent / archived no-op
    | None => Error(UnknownVersion)
    }
  | Retire(v) =>
    switch state.known->Dict.get(v) {
    | Some({status: Retired}) => Ok([]) // idempotent
    | Some({definition}) =>
      Ok(
        Array.concat(
          Array.concat(
            [VersionRetired(definition)],
            uiDeregisterEvents(definition.id, definition.uiFragments),
          ),
          promoteEvents(state, v),
        ),
      )
    | None => Error(UnknownVersion)
    }
  | ReportIncompatibility(def) => Ok([IncompatiblePluginDetected(def)])
  }

// Apply one event. `current` is recomputed (highest Connected) after every
// status change — VersionSuperseded / VersionPromoted are informational records
// for the history view and carry no state change beyond what the preceding
// VersionConnected / VersionDisconnected already applied.
let evolve = (state: state, event) => {
  let setStatus = (v, status, definition) => {
    let known = state.known->Dict.copy
    known->Dict.set(v, {definition, status})
    {current: highestConnected(known), known}
  }
  switch event {
  | VersionConnected(def) => setStatus(def.version, Connected, def)
  | VersionActivated(def) => setStatus(def.version, Connected, def)
  | VersionDisconnected(def) => setStatus(def.version, Disconnected, def)
  | VersionDeactivated(def) => setStatus(def.version, Inactive, def)
  | VersionRetired(def) => setStatus(def.version, Retired, def)
  | VersionDetected(_)
  | VersionSuperseded(_)
  | VersionPromoted(_)
  | IncompatiblePluginDetected(_)
  | UIFragmentRegistered(_)
  | UIFragmentUpdated(_)
  | UIFragmentDeregistered(_) => state
  }
}
