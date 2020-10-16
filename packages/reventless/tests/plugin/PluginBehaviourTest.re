open Jest;

module PluginTest =
  Reventless.BehaviourTest.Make(PluginSpec, PluginBehaviour);
open PluginTest;
open PluginSpec;
open PluginFixture;

describe("Plugin Aggregate", () => {
  test("Heartbeat (first)", () =>
    givenEvents([])
    |> whenCmd(Heartbeat)
    |> thenEvents([UnknownPluginDetected])
  );

  test("Heartbeat again", () =>
    givenEvents([UnknownPluginDetected])
    |> whenCmd(Heartbeat)
    |> thenEvents([UnknownPluginDetected])
  );

  test("ConnectPlugin", () =>
    givenEvents([UnknownPluginDetected])
    |> whenCmd(ConnectPlugin(pluginDefinition))
    |> thenEvents([PluginConnected(pluginDefinition)])
  );

  test("ConnectPlugin again", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(pluginDefinition)])
    |> whenCmd(ConnectPlugin(pluginDefinition))
    |> thenEvents([])
  );

  test("DisconnectPlugin", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(pluginDefinition)])
    |> whenCmd(DisconnectPlugin)
    |> thenEvents([PluginDisconnected(pluginDefinition)])
  );

  test("Heartbeat (re-connect)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDisconnected(pluginDefinition),
    ])
    |> whenCmd(Heartbeat)
    |> thenEvents([PluginReconnected(pluginDefinition)])
  );

  test("ConnectPlugin (disconnected)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDisconnected(pluginDefinition),
    ])
    |> whenCmd(ConnectPlugin(pluginDefinition))
    |> thenEvents([])
  );

  test("DeactivatePlugin", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(pluginDefinition)])
    |> whenCmd(DeactivatePlugin)
    |> thenEvents([PluginDeactivated(pluginDefinition)])
  );

  test("DeactivatePlugin (disconnected)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDisconnected(pluginDefinition),
    ])
    |> whenCmd(DeactivatePlugin)
    |> thenEvents([PluginDeactivated(pluginDefinition)])
  );

  test("ActivatePlugin (deactivated, disconnected)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDisconnected(pluginDefinition),
      PluginDeactivated(pluginDefinition),
    ])
    |> whenCmd(ActivatePlugin)
    |> thenEvents([PluginActivated(pluginDefinition)])
  );

  test("ConnectPlugin (inactive)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDeactivated(pluginDefinition),
    ])
    |> whenCmd(ConnectPlugin(pluginDefinition))
    |> thenEvents([])
  );

  test("ActivatePlugin again", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDeactivated(pluginDefinition),
    ])
    |> whenCmd(ActivatePlugin)
    |> thenEvents([PluginActivated(pluginDefinition)])
  );

  test("Heartbeat (re-connected after re-activated)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDeactivated(pluginDefinition),
      PluginActivated(pluginDefinition),
    ])
    |> whenCmd(Heartbeat)
    |> thenEvents([PluginReconnected(pluginDefinition)])
  );

  test("ConnectPlugin (re-activated)", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDeactivated(pluginDefinition),
      PluginActivated(pluginDefinition),
    ])
    |> whenCmd(ConnectPlugin(pluginDefinition))
    |> thenEvents([])
  );
});
