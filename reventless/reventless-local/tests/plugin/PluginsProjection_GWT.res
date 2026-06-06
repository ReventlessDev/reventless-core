open ReventlessCore
open PluginSpec
open Plugin_Fixtures
module PluginsProjectionTest = ReventlessGwt.MultiSourceProjection_GWT.Make(PluginsProjection.PluginMapping)
open PluginsProjectionTest

describe("PluginsProjection:", () => {
  test("UnknownPluginDetected", () =>
    givenEvents([])->whenEvent(UnknownPluginDetected)->thenNoState
  )

  test("UnknownPluginDetected (already detected)", () =>
    givenEvents([UnknownPluginDetected])->whenEvent(UnknownPluginDetected)->thenNoState
  )

  test("Connected", () =>
    givenEvents([UnknownPluginDetected])
    ->whenEvent(Connected(pluginDefinition))
    ->thenState({...state, status: Connected})
  )

  test("Connected (not detected before)", () =>
    givenEvents([])
    ->whenEvent(Connected(pluginDefinition))
    ->thenState({...state, status: Connected})
  )

  test("Disconnected", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenEvent(Disconnected(pluginDefinition))
    ->thenState({...state, status: Disconnected})
  )

  test("Disconnected (not connected before)", () =>
    givenEvents([])
    ->whenEvent(Disconnected(pluginDefinition))
    ->thenState({...state, status: Disconnected})
  )

  test("Deactivated", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenEvent(Deactivated(pluginDefinition))
    ->thenState({...state, status: Inactive})
  )

  test("Deactivated (not connected before)", () =>
    givenEvents([])
    ->whenEvent(Deactivated(pluginDefinition))
    ->thenState({...state, status: Inactive})
  )

  test("Activated", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition), Deactivated(pluginDefinition)])
    ->whenEvent(Activated(pluginDefinition))
    ->thenState({...state, status: Disconnected})
  )

  test("Activated (not deactivated before)", () =>
    givenEvents([])
    ->whenEvent(Activated(pluginDefinition))
    ->thenState({...state, status: Disconnected})
  )

  test("Reconnected (after activated)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
      Activated(pluginDefinition),
    ])
    ->whenEvent(Reconnected(pluginDefinition))
    ->thenState({...state, status: Connected})
  )

  test("Reconnected (not disconnected before)", () =>
    givenEvents([])
    ->whenEvent(Reconnected(pluginDefinition))
    ->thenState({...state, status: Connected})
  )

  test("UIFragmentRegistered is ignored by plugin read model", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenEvent(
      UIFragmentRegistered({pluginId: pluginDefinition.id, manifest: uiManifest}),
    )
    ->thenState({...state, status: Connected})
  )

  test("UIFragmentDeregistered is ignored by plugin read model", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenEvent(UIFragmentDeregistered({pluginId: pluginDefinition.id}))
    ->thenState({...state, status: Connected})
  )

  // ── Retired — deploy-driven supersession of an older plugin version ──────
  //
  // Issued by the platform deploy hook (publishRetireForOlderPluginVersions).
  // Maps to status: Retired — distinct from Inactive (admin Deactivate). Both
  // are filtered from the manifest, but Retired means "obsoleted by a newer
  // version" and is revivable only by the version's own Heartbeat.

  test("Retired on a Connected row yields status: Retired", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenEvent(Retired(pluginDefinition))
    ->thenState({...state, status: Retired})
  )

  test("Retired on a Disconnected row also yields status: Retired", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
    ])
    ->whenEvent(Retired(pluginDefinition))
    ->thenState({...state, status: Retired})
  )

  test("Retired with no prior row creates one at status: Retired", () =>
    givenEvents([])
    ->whenEvent(Retired(pluginDefinition))
    ->thenState({...state, status: Retired})
  )

  test("Reconnected after Retired yields status: Connected (heartbeat revival)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Retired(pluginDefinition),
    ])
    ->whenEvent(Reconnected(pluginDefinition))
    ->thenState({...state, status: Connected})
  )

  // ── IncompatiblePluginDetected — observation only, no status change ──────

  test("IncompatiblePluginDetected leaves a Connected row unchanged", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenEvent(IncompatiblePluginDetected(pluginDefinition))
    ->thenState({...state, status: Connected})
  )

  test("IncompatiblePluginDetected on a never-seen plugin does not create a row", () =>
    givenEvents([])
    ->whenEvent(IncompatiblePluginDetected(pluginDefinition))
    ->thenNoState
  )
})
