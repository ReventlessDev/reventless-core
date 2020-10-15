open Jest;

module PluginTest = Reventless.ViewTest.Make(PluginSpec, PluginView);
open PluginTest;
open PluginSpec;
open PluginFixture;

describe("Plugin: View", () => {
  test("detected", () =>
    givenEvents([])  //
    |> whenEvent(UnknownPluginDetected)
    |> thenNoState
  );

  test("already detected", () =>
    givenEvents([UnknownPluginDetected])
    |> whenEvent(UnknownPluginDetected)
    |> thenNoState
  );

  test("connected", () =>
    givenEvents([UnknownPluginDetected])
    |> whenEvent(PluginConnected(pluginDefinition))
    |> thenState({...state, status: Connected})
  );

  test("disconnected", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(pluginDefinition)])
    |> whenEvent(PluginDisconnected)
    |> thenState({...state, status: Disconnected})
  );

  test("deactivated", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(pluginDefinition)])
    |> whenEvent(PluginDeactivated)
    |> thenState({...state, status: Inactive})
  );

  test("activated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDeactivated,
    ])
    |> whenEvent(PluginActivated)
    |> thenState({...state, status: Disconnected})
  );

  test("re-connected after activated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDeactivated,
      PluginActivated,
    ])
    |> whenEvent(PluginReconnected)
    |> thenState({...state, status: Connected})
  );
});
