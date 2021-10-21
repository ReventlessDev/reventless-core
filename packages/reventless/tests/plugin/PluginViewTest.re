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
    |> whenEvent(PluginConnected(pluginDefinition, apiFragmentDescriptions))
    |> thenState({...state, status: Connected})
  );

  test("PluginDisconnected", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenEvent(
         PluginDisconnected(pluginDefinition, apiFragmentDescriptions),
       )
    |> thenState({...state, status: Disconnected})
  );

  test("PluginDeactivated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenEvent(
         PluginDeactivated(pluginDefinition, apiFragmentDescriptions),
       )
    |> thenState({...state, status: Inactive})
  );

  test("PluginActivated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
      PluginDeactivated(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenEvent(PluginActivated(pluginDefinition, apiFragmentDescriptions))
    |> thenState({...state, status: Disconnected})
  );

  test("PluginReconnected (after activated)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
      PluginDeactivated(pluginDefinition, apiFragmentDescriptions),
      PluginActivated(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenEvent(
         PluginReconnected(pluginDefinition, apiFragmentDescriptions),
       )
    |> thenState({...state, status: Connected})
  );
});
