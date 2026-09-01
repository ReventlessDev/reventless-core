@@reventless.spec("Plugin")

open Reventless.Plugin

// Alias, not `open`: the lifecycle states are named qualified in
// `commandTransition` below, and an `open` would pull the whole view's namespace
// in for four constructors.
module Plugins = PluginsReadModelSpec

// The Plugin aggregate is keyed by plugin **name** (not name@version). One
// instance owns the whole lifecycle of every version of that name, deciding
// supersession synchronously. Version-scoped commands carry the `version`
// the transition targets; the ExtensionPoint→Plugin mapping supplies it
// (translated from the transport-level `name@version` id — Approach 1).
// Order is load-bearing: sury strands constructors declared after a run of two or
// more same-shaped ones, so the `pluginDefinition` pair must lead (DZakh/sury#392).
@schema
type command =
  | @noApi Connect(pluginDefinition)
  // Records a protocol-version incompatibility without changing connection state.
  | @noApi ReportIncompatibility(pluginDefinition)
  | @noApi Heartbeat(version)
  // Deploy-time re-detect (from RedetectPlugin). Forces the connect handshake to
  // re-run for an already-connected version so its definition is refreshed on the
  // row — unlike Heartbeat, which no-ops a connected keep-alive.
  | @noApi Redetect(version)
  | @noApi Disconnect(version)
  // Admin lifecycle commands — API-exposed (auto-derived admin mutations,
  // Cognito group-gated). `version` selects which known version to act on.
  //
  // Inline records, unlike the `@noApi` commands above, and the difference is the
  // API. A positional payload publishes its argument as `_0`, which names nothing:
  // a caller cannot match it against a field it holds, and a coercion failure says
  // `Variable '_0'` rather than what was missing. These three are the ones a person
  // calls, so their argument carries its own name.
  | Activate({version: version})
  | Deactivate({version: version})
  // Manual admin retirement of a specific version (archive). Distinct from the
  // automatic `Superseded` transition (which is decided, not commanded).
  | Retire({version: version})

// Carries both the superseded and the superseding version's full definition —
// a deterministic trigger for version-to-version schema/data migrations
// (analysis §6.2.4).
@schema
type versionSupersededData = {
  supersededVersion: version,
  supersededDefinition: pluginDefinition,
  newVersion: version,
  newDefinition: pluginDefinition,
}

@schema
type event =
  // A heartbeat arrived for a version the aggregate has not yet connected —
  // triggers the ConnectPlugin handshake (replaces UnknownPluginDetected). The
  // version lets the EP rebuild the `name@version` id for the handshake.
  | VersionDetected(version)
  // A version completed the connect handshake (replaces Connected/Reconnected).
  | VersionConnected(pluginDefinition)
  // A newer version connected and took over as current.
  | VersionSuperseded(versionSupersededData)
  // An older still-live version became current again (rollback): the current
  // version disconnected/deactivated/retired and a lower live version was promoted.
  | VersionPromoted(pluginDefinition)
  // A version's heartbeats timed out (EP disconnect schedule).
  | VersionDisconnected(pluginDefinition)
  // Admin transitions.
  | VersionActivated(pluginDefinition)
  | VersionDeactivated(pluginDefinition)
  // Manual admin retirement (archive) of a specific version.
  | VersionRetired(pluginDefinition)
  // Protocol incompatibility recorded at connect; connection still proceeds.
  | IncompatiblePluginDetected(pluginDefinition)

@schema
type error =
  // Targeted version is unknown to this plugin name.
  | UnknownVersion
  // Admin command targets a version not in the state the command requires.
  | AlreadyConnected
  | IsDisconnected
  | IsInactive

// The edges must agree with `decide`; `Platform_Admin_Structure` reads them off
// the assembled structure rather than restating them.
type lifecycleState = Plugins.status

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  // The handshake brings the version's row into being, so it runs from no state
  // — `decide` accepts it against an unknown version and against every status
  // but `Connected`, where it is a definition refresh rather than a move.
  | Connect(_) => Creates(Plugins.Connected)
  // Neither records a move: an incompatibility is noted beside the row, and a
  // heartbeat or a re-detect refreshes one that is already where it belongs.
  | ReportIncompatibility(_) | Heartbeat(_) | Redetect(_) => Unrestricted
  // A heartbeat timing out is the only way a row reaches `Disconnected`, and
  // `decide` moves the row for exactly one status — anything else is a stray
  // disconnect it tolerates without emitting.
  | Disconnect(_) => Moves([Plugins.Connected], Plugins.Disconnected)
  | Activate(_) => Moves([Plugins.Inactive, Plugins.Retired], Plugins.Connected)
  | Deactivate(_) => Moves([Plugins.Connected, Plugins.Disconnected], Plugins.Inactive)
  | Retire(_) =>
    Moves([Plugins.Connected, Plugins.Disconnected, Plugins.Inactive], Plugins.Retired)
  }
}
