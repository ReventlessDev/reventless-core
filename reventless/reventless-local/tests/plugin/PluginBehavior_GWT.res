open ReventlessCore
open PluginSpec
open Plugin_Fixtures
module PluginTest = ReventlessGwt.Behavior_GWT.MakeFromAggregate(PluginSpec, PluginBehavior)
open PluginTest

describe("PluginBehavior:", () => {
  test("Heartbeat (first)", () =>
    givenEvents([])->whenCmd(Heartbeat)->thenEvents([UnknownPluginDetected])
  )

  test("Heartbeat (again)", () =>
    givenEvents([UnknownPluginDetected])->whenCmd(Heartbeat)->thenEvents([UnknownPluginDetected])
  )

  test("Heartbeat (connected)", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(Heartbeat)
    ->thenNoEvent
  )

  test("Heartbeat (inactive)", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition), Deactivated(pluginDefinition)])
    ->whenCmd(Heartbeat)
    ->thenNoEvent
  )

  test("Connect", () =>
    givenEvents([UnknownPluginDetected])
    ->whenCmd(Connect(pluginDefinition))
    ->thenEvents([Connected(pluginDefinition)])
  )

  test("Connect (after multiple Heartbeats)", () =>
    givenEvents([UnknownPluginDetected, UnknownPluginDetected])
    ->whenCmd(Connect(pluginDefinition))
    ->thenEvents([Connected(pluginDefinition)])
  )

  test("Connect (again)", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(AlreadyConnected)
  )

  test("Disconnect", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(Disconnect)
    ->thenEvents([Disconnected(pluginDefinition)])
  )

  test("Heartbeat (re-connect)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
    ])
    ->whenCmd(Heartbeat)
    ->thenEvents([Reconnected(pluginDefinition)])
  )

  test("Connect (disconnected)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
    ])
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(IsDisconnected)
  )

  test("Deactivate", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(Deactivate)
    ->thenEvents([Deactivated(pluginDefinition)])
  )

  test("Deactivate (disconnected)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
    ])
    ->whenCmd(Deactivate)
    ->thenEvents([Deactivated(pluginDefinition)])
  )

  test("Activate (deactivated, disconnected)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
      Deactivated(pluginDefinition),
    ])
    ->whenCmd(Activate)
    ->thenEvents([Activated(pluginDefinition)])
  )

  test("Connect (inactive)", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition), Deactivated(pluginDefinition)])
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(IsInactive)
  )

  test("Activate again", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition), Deactivated(pluginDefinition)])
    ->whenCmd(Activate)
    ->thenEvents([Activated(pluginDefinition)])
  )

  test("Heartbeat (re-connected after re-activated)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
      Activated(pluginDefinition),
    ])
    ->whenCmd(Heartbeat)
    ->thenEvents([Reconnected(pluginDefinition)])
  )

  test("Connect (re-activated)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
      Activated(pluginDefinition),
    ])
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(IsDisconnected)
  )

  test("Connect (with UI fragments) emits UIFragmentRegistered", () =>
    givenEvents([UnknownPluginDetected])
    ->whenCmd(Connect(pluginDefinitionWithUI))
    ->thenEvents([
      Connected(pluginDefinitionWithUI),
      UIFragmentRegistered({pluginId: pluginDefinitionWithUI.id, manifest: uiManifest}),
    ])
  )

  test("Disconnect (with UI fragments) emits UIFragmentDeregistered", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinitionWithUI)])
    ->whenCmd(Disconnect)
    ->thenEvents([
      Disconnected(pluginDefinitionWithUI),
      UIFragmentDeregistered({pluginId: pluginDefinitionWithUI.id}),
    ])
  )

  test("Deactivate (connected, with UI fragments) emits UIFragmentDeregistered", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinitionWithUI)])
    ->whenCmd(Deactivate)
    ->thenEvents([
      Deactivated(pluginDefinitionWithUI),
      UIFragmentDeregistered({pluginId: pluginDefinitionWithUI.id}),
    ])
  )

  test("Heartbeat (re-connect with UI fragments) emits UIFragmentRegistered", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinitionWithUI),
      Disconnected(pluginDefinitionWithUI),
    ])
    ->whenCmd(Heartbeat)
    ->thenEvents([
      Reconnected(pluginDefinitionWithUI),
      UIFragmentRegistered({pluginId: pluginDefinitionWithUI.id, manifest: uiManifest}),
    ])
  )

  test("Deactivate (disconnected, with UI fragments) emits no UIFragmentDeregistered", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinitionWithUI),
      Disconnected(pluginDefinitionWithUI),
    ])
    ->whenCmd(Deactivate)
    ->thenEvents([Deactivated(pluginDefinitionWithUI)])
  )

  // ── Retire — deploy-driven supersession of an older plugin version ───────
  //
  // Issued by the platform deploy hook (publishRetireForOlderPluginVersions).
  // Lands in the Retired state — distinct from Inactive (admin Deactivate):
  // an admin cannot Activate it back, but the version's own Heartbeat
  // (rollback / redeploy) revives it through Reconnected.

  test("Retire (connected)", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(Retire)
    ->thenEvents([Retired(pluginDefinition)])
  )

  test("Retire (connected, with UI fragments) emits UIFragmentDeregistered", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinitionWithUI)])
    ->whenCmd(Retire)
    ->thenEvents([
      Retired(pluginDefinitionWithUI),
      UIFragmentDeregistered({pluginId: pluginDefinitionWithUI.id}),
    ])
  )

  test("Retire (disconnected) emits Retired without UI fragment events", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinitionWithUI),
      Disconnected(pluginDefinitionWithUI),
    ])
    ->whenCmd(Retire)
    ->thenEvents([Retired(pluginDefinitionWithUI)])
  )

  test("Retire (inactive/admin-suspended) supersedes via Retired", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
    ])
    ->whenCmd(Retire)
    ->thenEvents([Retired(pluginDefinition)])
  )

  test("Retire (retired) is idempotent", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Retired(pluginDefinition),
    ])
    ->whenCmd(Retire)
    ->thenNoEvent
  )

  test("Retire (detected) is a no-op (no events to register yet)", () =>
    givenEvents([UnknownPluginDetected])
    ->whenCmd(Retire)
    ->thenNoEvent
  )

  test("Retire on a never-detected plugin returns NotExisting", () =>
    givenEvents([])
    ->whenCmd(Retire)
    ->thenError(NotExisting)
  )

  test("Activate (retired) is rejected — superseded versions are not admin-reactivatable", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Retired(pluginDefinition),
    ])
    ->whenCmd(Activate)
    ->thenError(IsRetired)
  )

  test("Deactivate (retired) is rejected", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition), Retired(pluginDefinition)])
    ->whenCmd(Deactivate)
    ->thenError(IsRetired)
  )

  test("Connect (retired) is rejected", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition), Retired(pluginDefinition)])
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(IsRetired)
  )

  test("Heartbeat (retired) revives via Reconnected", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Retired(pluginDefinition),
    ])
    ->whenCmd(Heartbeat)
    ->thenEvents([Reconnected(pluginDefinition)])
  )

  test("Heartbeat (retired, with UI fragments) emits Reconnected + UIFragmentRegistered", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinitionWithUI),
      Retired(pluginDefinitionWithUI),
    ])
    ->whenCmd(Heartbeat)
    ->thenEvents([
      Reconnected(pluginDefinitionWithUI),
      UIFragmentRegistered({pluginId: pluginDefinitionWithUI.id, manifest: uiManifest}),
    ])
  )

  // ── NotConnected / Detected exhaustive negative-case coverage ────────────
  //
  // Surfaces the NotExisting error path so accidental relaxations show up
  // immediately rather than failing at runtime.

  test("Connect on never-detected plugin returns NotExisting", () =>
    givenEvents([])->whenCmd(Connect(pluginDefinition))->thenError(NotExisting)
  )

  test("Disconnect on never-detected plugin returns NotExisting", () =>
    givenEvents([])->whenCmd(Disconnect)->thenError(NotExisting)
  )

  test("Activate on never-detected plugin returns NotExisting", () =>
    givenEvents([])->whenCmd(Activate)->thenError(NotExisting)
  )

  test("Deactivate on never-detected plugin returns NotExisting", () =>
    givenEvents([])->whenCmd(Deactivate)->thenError(NotExisting)
  )

  test("ReportIncompatibility on never-detected plugin returns NotExisting", () =>
    givenEvents([])
    ->whenCmd(ReportIncompatibility(pluginDefinition))
    ->thenError(NotExisting)
  )

  // ── ReportIncompatibility — protocol-version drift observability ─────────
  //
  // ReportIncompatibility never changes connection state — it only records an
  // IncompatiblePluginDetected event for operator visibility.

  test("ReportIncompatibility (detected) records IncompatiblePluginDetected", () =>
    givenEvents([UnknownPluginDetected])
    ->whenCmd(ReportIncompatibility(pluginDefinition))
    ->thenEvents([IncompatiblePluginDetected(pluginDefinition)])
  )

  test("ReportIncompatibility (connected) records IncompatiblePluginDetected", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(ReportIncompatibility(pluginDefinition))
    ->thenEvents([IncompatiblePluginDetected(pluginDefinition)])
  )

  test("ReportIncompatibility (disconnected) records IncompatiblePluginDetected", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
    ])
    ->whenCmd(ReportIncompatibility(pluginDefinition))
    ->thenEvents([IncompatiblePluginDetected(pluginDefinition)])
  )

  test("ReportIncompatibility (inactive) records IncompatiblePluginDetected", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
    ])
    ->whenCmd(ReportIncompatibility(pluginDefinition))
    ->thenEvents([IncompatiblePluginDetected(pluginDefinition)])
  )
})
