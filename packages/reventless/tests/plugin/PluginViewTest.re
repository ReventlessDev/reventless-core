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
    |> whenEvent(PluginConnected(plugin1))
    |> thenState({...state1, status: Connected})
  );

  test("disconnected", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(plugin1)])
    |> whenEvent(PluginDisconnected)
    |> thenState({...state1, status: Disconnected})
  );

  test("deactivated", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(plugin1)])
    |> whenEvent(PluginDeactivated)
    |> thenState({...state1, status: Inactive})
  );

  test("activated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDeactivated,
    ])
    |> whenEvent(PluginActivated)
    |> thenState({...state1, status: Disconnected})
  );

  test("re-connected after activated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDeactivated,
      PluginActivated,
    ])
    |> whenEvent(PluginReconnected)
    |> thenState({...state1, status: Connected})
  );
});
