open ReventlessCore
open PluginSpec
open Plugin_Fixtures
module PluginTest = ReventlessGwt.Behavior_GWT.MakeFromAggregate(PluginSpec, PluginBehavior)
open PluginTest

// Name-keyed lifecycle aggregate. Commands carry the version; the aggregate
// decides supersession / promotion from event-driven status in `known` and
// never reads wall-clock time.

let supersededV1ByV2 = VersionSuperseded({
  supersededVersion: "1",
  supersededDefinition: pluginDefinition,
  newVersion: "2",
  newDefinition: pluginDefinitionV2,
})

describe("PluginBehavior:", () => {
  // ── Detection → connect handshake ──────────────────────────────────────────
  test("Heartbeat for an unknown version triggers detection", () =>
    givenEvents([])->whenCmd(Heartbeat("1"))->thenEvents([VersionDetected("1")])
  )

  test("Heartbeat again while still only detected re-triggers detection", () =>
    // VersionDetected does not add the version to `known`, so a repeat heartbeat
    // re-emits it (idempotent handshake trigger).
    givenEvents([VersionDetected("1")])->whenCmd(Heartbeat("1"))->thenEvents([VersionDetected("1")])
  )

  test("Connect completes the handshake", () =>
    givenEvents([VersionDetected("1")])
    ->whenCmd(Connect(pluginDefinition))
    ->thenEvents([VersionConnected(pluginDefinition)])
  )

  test("Connect is idempotent for an already-connected version", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenCmd(Connect(pluginDefinition))
    ->thenNoEvent
  )

  test("Heartbeat for a connected version is a keep-alive no-op", () =>
    givenEvents([VersionConnected(pluginDefinition)])->whenCmd(Heartbeat("1"))->thenNoEvent
  )

  // ── Disconnect / reconnect ─────────────────────────────────────────────────
  test("Disconnect of the current version", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenCmd(Disconnect("1"))
    ->thenEvents([VersionDisconnected(pluginDefinition)])
  )

  test("Heartbeat reconnects a disconnected version", () =>
    givenEvents([VersionConnected(pluginDefinition), VersionDisconnected(pluginDefinition)])
    ->whenCmd(Heartbeat("1"))
    ->thenEvents([VersionConnected(pluginDefinition)])
  )

  // ── Supersession (newer version takes over) ────────────────────────────────
  test("A higher version connecting supersedes the current one", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenCmd(Connect(pluginDefinitionV2))
    ->thenEvents([VersionConnected(pluginDefinitionV2), supersededV1ByV2])
  )

  test("A lower version connecting does not supersede the current one", () =>
    givenEvents([VersionConnected(pluginDefinitionV2)])
    ->whenCmd(Connect(pluginDefinition))
    ->thenEvents([VersionConnected(pluginDefinition)])
  )

  // ── Rollback (promote highest still-live on current loss) ───────────────────
  test("Disconnecting the current version promotes the highest live lower version", () =>
    givenEvents([VersionConnected(pluginDefinition), VersionConnected(pluginDefinitionV2)])
    ->whenCmd(Disconnect("2"))
    ->thenEvents([VersionDisconnected(pluginDefinitionV2), VersionPromoted(pluginDefinition)])
  )

  test("Disconnecting the current with no other live version promotes nothing", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenCmd(Disconnect("1"))
    ->thenEvents([VersionDisconnected(pluginDefinition)])
  )

  // ── Admin deactivate / activate ─────────────────────────────────────────────
  test("Deactivate the current version", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenCmd(Deactivate("1"))
    ->thenEvents([VersionDeactivated(pluginDefinition)])
  )

  test("Activate a deactivated version", () =>
    givenEvents([VersionConnected(pluginDefinition), VersionDeactivated(pluginDefinition)])
    ->whenCmd(Activate("1"))
    ->thenEvents([VersionActivated(pluginDefinition)])
  )

  test("Activate an unknown version errors", () =>
    givenEvents([])->whenCmd(Activate("9"))->thenError(UnknownVersion)
  )

  // ── Manual retire + un-retire (decision A) ─────────────────────────────────
  test("Retire the current version", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenCmd(Retire("1"))
    ->thenEvents([VersionRetired(pluginDefinition)])
  )

  test("Heartbeat does NOT revive a retired version (contrast with Disconnected)", () =>
    givenEvents([VersionConnected(pluginDefinition), VersionRetired(pluginDefinition)])
    ->whenCmd(Heartbeat("1"))
    ->thenNoEvent
  )

  test("Un-retire: admin Activate revives a retired version", () =>
    givenEvents([VersionConnected(pluginDefinition), VersionRetired(pluginDefinition)])
    ->whenCmd(Activate("1"))
    ->thenEvents([VersionActivated(pluginDefinition)])
  )

  // ── Incompatibility (observation only) ─────────────────────────────────────
  test("ReportIncompatibility records an event without changing state", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenCmd(ReportIncompatibility(pluginDefinition))
    ->thenEvents([IncompatiblePluginDetected(pluginDefinition)])
  )

  // ── UI fragments ────────────────────────────────────────────────────────────
  test("Connect with UI fragments emits UIFragmentRegistered", () =>
    givenEvents([VersionDetected("1")])
    ->whenCmd(Connect(pluginDefinitionWithUI))
    ->thenEvents([
      VersionConnected(pluginDefinitionWithUI),
      UIFragmentRegistered({pluginId: pluginDefinitionWithUI.id, manifest: uiManifest}),
    ])
  )

  test("Disconnect with UI fragments emits UIFragmentDeregistered", () =>
    givenEvents([VersionConnected(pluginDefinitionWithUI)])
    ->whenCmd(Disconnect("1"))
    ->thenEvents([
      VersionDisconnected(pluginDefinitionWithUI),
      UIFragmentDeregistered({pluginId: pluginDefinitionWithUI.id}),
    ])
  )
})
