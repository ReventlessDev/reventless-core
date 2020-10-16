open Jest;

module PluginTest = Reventless.ViewTest.Make(PluginSpec, PluginView);
open PluginTest;
open PluginSpec;
open PluginFixture;

describe("Plugin: View", () => {
  test("UnknownPluginDetected", () =>
    givenEvents([])  //
    |> whenEvent(UnknownPluginDetected)
    |> thenNoState
  );

  test("UnknownPluginDetected (already detected)", () =>
    givenEvents([UnknownPluginDetected])
    |> whenEvent(UnknownPluginDetected)
    |> thenNoState
  );

  test("PluginConnected", () =>
    givenEvents([UnknownPluginDetected])
    |> whenEvent(PluginConnected(pluginDefinition))
    |> thenState({...state, status: Connected})
  );

  test("PluginDisconnected", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(pluginDefinition)])
    |> whenEvent(PluginDisconnected(pluginDefinition))
    |> thenState({...state, status: Disconnected})
  );

  test("PluginDeactivated", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(pluginDefinition)])
    |> whenEvent(PluginDeactivated(pluginDefinition))
    |> thenState({...state, status: Inactive})
  );

  test("PluginActivated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDeactivated(pluginDefinition),
    ])
    |> whenEvent(PluginActivated(pluginDefinition))
    |> thenState({...state, status: Disconnected})
  );

  test("PluginReconnected (after activated)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDeactivated(pluginDefinition),
      PluginActivated(pluginDefinition),
    ])
    |> whenEvent(PluginReconnected(pluginDefinition))
    |> thenState({...state, status: Connected})
  );
});
