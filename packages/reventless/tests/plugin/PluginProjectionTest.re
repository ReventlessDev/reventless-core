open PluginSpec;
open PluginFixture;
include ProjectionTest.Make(
          PluginReadModelSpec,
          PluginProjection.PluginMapping,
        );

describe("PluginProjection:", () => {
  test("UnknownPluginDetected", () =>
    givenEvents([]) //
    ->whenEvent(UnknownPluginDetected)
    ->thenNoState
  );

  test("UnknownPluginDetected (already detected)", () =>
    givenEvents([UnknownPluginDetected])
    ->whenEvent(UnknownPluginDetected)
    ->thenNoState
  );

  test("Connected", () =>
    givenEvents([UnknownPluginDetected])
    ->whenEvent(Connected(pluginDefinition))
    ->thenState({...state, status: Connected})
  );

  test("Disconnected", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenEvent(Disconnected(pluginDefinition))
    ->thenState({...state, status: Disconnected})
  );

  test("Deactivated", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenEvent(Deactivated(pluginDefinition))
    ->thenState({...state, status: Inactive})
  );

  test("Activated", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
    ])
    ->whenEvent(Activated(pluginDefinition))
    ->thenState({...state, status: Disconnected})
  );

  test("Reconnected (after activated)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
      Activated(pluginDefinition),
    ])
    ->whenEvent(Reconnected(pluginDefinition))
    ->thenState({...state, status: Connected})
  );
});
