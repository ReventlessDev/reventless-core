open ReventlessCore
open PluginSpec
open PluginFixtures
module PluginProjectionTest = ReventlessGwt.MultiSourceProjection_GWT.Make(PluginProjection.PluginMapping)
open PluginProjectionTest

describe("PluginProjection:", () => {
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
})
