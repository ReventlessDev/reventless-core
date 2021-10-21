open Jest;

module PluginTest =
  Reventless.BehaviourTest.Make(PluginSpec, PluginBehaviour);
open PluginTest;
open PluginSpec;
open PluginFixture;

describe("PluginBehaviour:", () => {
  test("Heartbeat (first)", () =>
    givenEvents([])
    |> whenCmd(Heartbeat)
    |> thenEvents([UnknownPluginDetected])
  );

  test("Heartbeat (again)", () =>
    givenEvents([UnknownPluginDetected])
    |> whenCmd(Heartbeat)
    |> thenEvents([UnknownPluginDetected])
  );

  test("ConnectPlugin", () =>
    givenEvents([UnknownPluginDetected])
    |> whenCmd(ConnectPlugin(pluginDefinition, apiFragmentDescriptions))
    |> thenEvents([
         PluginConnected(pluginDefinition, apiFragmentDescriptions),
       ])
  );

  test("ConnectPlugin (after multiple Heartbeats)", () =>
    givenEvents([UnknownPluginDetected, UnknownPluginDetected])
    |> whenCmd(ConnectPlugin(pluginDefinition, apiFragmentDescriptions))
    |> thenEvents([
         PluginConnected(pluginDefinition, apiFragmentDescriptions),
       ])
  );

  test("ConnectPlugin (again)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenCmd(ConnectPlugin(pluginDefinition, apiFragmentDescriptions))
    |> thenError(PluginIsConnected)
  );

  test("DisconnectPlugin", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenCmd(DisconnectPlugin)
    |> thenEvents([
         PluginDisconnected(pluginDefinition, apiFragmentDescriptions),
       ])
  );

  test("Heartbeat (re-connect)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
      PluginDisconnected(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenCmd(Heartbeat)
    |> thenEvents([
         PluginReconnected(pluginDefinition, apiFragmentDescriptions),
       ])
  );

  test("ConnectPlugin (disconnected)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
      PluginDisconnected(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenCmd(ConnectPlugin(pluginDefinition, apiFragmentDescriptions))
    |> thenError(PluginIsDisconnected)
  );

  test("DeactivatePlugin", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenCmd(DeactivatePlugin)
    |> thenEvents([
         PluginDeactivated(pluginDefinition, apiFragmentDescriptions),
       ])
  );

  test("DeactivatePlugin (disconnected)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
      PluginDisconnected(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenCmd(DeactivatePlugin)
    |> thenEvents([
         PluginDeactivated(pluginDefinition, apiFragmentDescriptions),
       ])
  );

  test("ActivatePlugin (deactivated, disconnected)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
      PluginDisconnected(pluginDefinition, apiFragmentDescriptions),
      PluginDeactivated(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenCmd(ActivatePlugin)
    |> thenEvents([
         PluginActivated(pluginDefinition, apiFragmentDescriptions),
       ])
  );

  test("ConnectPlugin (inactive)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
      PluginDeactivated(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenCmd(ConnectPlugin(pluginDefinition, apiFragmentDescriptions))
    |> thenError(PluginIsInactive)
  );

  test("ActivatePlugin again", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
      PluginDeactivated(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenCmd(ActivatePlugin)
    |> thenEvents([
         PluginActivated(pluginDefinition, apiFragmentDescriptions),
       ])
  );

  test("Heartbeat (re-connected after re-activated)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
      PluginDeactivated(pluginDefinition, apiFragmentDescriptions),
      PluginActivated(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenCmd(Heartbeat)
    |> thenEvents([
         PluginReconnected(pluginDefinition, apiFragmentDescriptions),
       ])
  );

  test("ConnectPlugin (re-activated)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition, apiFragmentDescriptions),
      PluginDeactivated(pluginDefinition, apiFragmentDescriptions),
      PluginActivated(pluginDefinition, apiFragmentDescriptions),
    ])
    |> whenCmd(ConnectPlugin(pluginDefinition, apiFragmentDescriptions))
    |> thenError(PluginIsDisconnected)
  );
});
