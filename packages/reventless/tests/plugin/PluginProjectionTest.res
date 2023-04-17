open PluginSpec
open PluginFixtures
module PluginProjectionTest = ProjectionTest.Make(PluginProjection.PluginMapping)
open PluginProjectionTest

describe("PluginProjection:", () => {
  test("UnknownPluginDetected", () =>
    givenEvents(list{})->whenEvent(UnknownPluginDetected)->thenNoState
  )

  test("UnknownPluginDetected (already detected)", () =>
    givenEvents(list{UnknownPluginDetected})->whenEvent(UnknownPluginDetected)->thenNoState
  )

  test("Connected", () =>
    givenEvents(list{UnknownPluginDetected})
    ->whenEvent(Connected(pluginDefinition))
    ->thenState({...state, status: Connected})
  )

  test("Disconnected", () =>
    givenEvents(list{UnknownPluginDetected, Connected(pluginDefinition)})
    ->whenEvent(Disconnected(pluginDefinition))
    ->thenState({...state, status: Disconnected})
  )

  test("Deactivated", () =>
    givenEvents(list{UnknownPluginDetected, Connected(pluginDefinition)})
    ->whenEvent(Deactivated(pluginDefinition))
    ->thenState({...state, status: Inactive})
  )

  test("Activated", () =>
    givenEvents(list{
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
    })
    ->whenEvent(Activated(pluginDefinition))
    ->thenState({...state, status: Disconnected})
  )

  test("Reconnected (after activated)", () =>
    givenEvents(list{
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
      Activated(pluginDefinition),
    })
    ->whenEvent(Reconnected(pluginDefinition))
    ->thenState({...state, status: Connected})
  )
})
