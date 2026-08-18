@@reventless.spec("Plugin")

open Reventless.Plugin

// The linked view whose lifecycle the `@transition` edges below are written in
// terms of. An alias rather than an `open`: the PPX strips `@transition` before
// the typechecker, so the state constructors never reach it as identifiers and
// an `open` would resolve nothing and earn an unused-open warning. Naming the
// qualifier after the view also matches how an ordinary spec reads its edges
// (`Orders.Placed`, `Products.Listed`).
module Plugins = PluginsReadModelSpec

// The Plugin aggregate is keyed by plugin **name** (not name@version). One
// instance owns the whole lifecycle of every version of that name, deciding
// supersession synchronously. Version-scoped commands carry the `version`
// the transition targets; the ExtensionPoint→Plugin mapping supplies it
// (translated from the transport-level `name@version` id — Approach 1).
@schema
type command =
  | @noApi Heartbeat(version)
  // Deploy-time re-detect (from RedetectPlugin). Forces the connect handshake to
  // re-run for an already-connected version so its definition is refreshed on the
  // row — unlike Heartbeat, which no-ops a connected keep-alive.
  | @noApi Redetect(version)
  | @noApi Connect(pluginDefinition)
  | @noApi Disconnect(version)
  // Admin lifecycle commands — API-exposed (auto-derived admin mutations,
  // Cognito group-gated). `version` selects which known version to act on.
  //
  // The `@transition` edges name the states of the linked view's lifecycle
  // (`PluginsReadModelSpec.status`) and are the same ones `decide` accepts
  // below — `Activate` on a version the admin suspended or archived,
  // `Deactivate` on one that is live either way, `Retire` on anything not
  // already retired. `Platform_Admin_Structure` reads them off this schema
  // rather than restating them, so the board and the behaviour cannot drift.
  | @transition(([Plugins.Inactive, Plugins.Retired]) => Plugins.Connected) Activate(version)
  | @transition(([Plugins.Connected, Plugins.Disconnected]) => Plugins.Inactive) Deactivate(version)
  // Records a protocol-version incompatibility without changing connection state.
  | @noApi ReportIncompatibility(pluginDefinition)
  // Manual admin retirement of a specific version (archive). Distinct from the
  // automatic `Superseded` transition (which is decided, not commanded).
  | @transition(([Plugins.Connected, Plugins.Disconnected, Plugins.Inactive]) => Plugins.Retired)
  Retire(version)

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
