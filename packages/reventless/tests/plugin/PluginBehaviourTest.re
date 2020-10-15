open Jest;

module PluginTest =
  Reventless.BehaviourTest.Make(PluginSpec, PluginBehaviour);
open PluginTest;
open PluginSpec;
open PluginFixture;

describe("Plugin Aggregate", () => {
  test("detected on first heartbeat", () =>
    givenEvents([])
    |> whenCmd(Heartbeat)
    |> thenEvents([UnknownPluginDetected])
  );

  test("ignored further heartbeat", () =>
    givenEvents([UnknownPluginDetected])
    |> whenCmd(Heartbeat)
    |> thenEvents([])
  );

  test("connected", () =>
    givenEvents([UnknownPluginDetected])
    |> whenCmd(ConnectPlugin(pluginDefinition))
    |> thenEvents([PluginConnected(pluginDefinition)])
  );

  test("ignored further connect when connected", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(pluginDefinition)])
    |> whenCmd(ConnectPlugin(pluginDefinition))
    |> thenEvents([])
  );

  test("disconnected", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(pluginDefinition)])
    |> whenCmd(DisconnectPlugin)
    |> thenEvents([PluginDisconnected])
  );

  test("re-connected by heartbeat", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDisconnected,
    ])
    |> whenCmd(Heartbeat)
    |> thenEvents([PluginReconnected])
  );

  test("ignore further connect when disconnected", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDisconnected,
    ])
    |> whenCmd(ConnectPlugin(pluginDefinition))
    |> thenEvents([])
  );

  test("deactivated", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(pluginDefinition)])
    |> whenCmd(DeactivatePlugin)
    |> thenEvents([PluginDeactivated])
  );

  test("deactivated when disconnected", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDisconnected,
    ])
    |> whenCmd(DeactivatePlugin)
    |> thenEvents([PluginDeactivated])
  );

  test("re-activated after deactivated when disconnected", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDisconnected,
      PluginDeactivated,
    ])
    |> whenCmd(ActivatePlugin)
    |> thenEvents([PluginActivated])
  );

  test("ignore further connect when inactive", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDeactivated,
    ])
    |> whenCmd(ConnectPlugin(pluginDefinition))
    |> thenEvents([])
  );

  test("re-activated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDeactivated,
    ])
    |> whenCmd(ActivatePlugin)
    |> thenEvents([PluginActivated])
  );

  test("re-connected by heartbeat after re-activated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDeactivated,
      PluginActivated,
    ])
    |> whenCmd(Heartbeat)
    |> thenEvents([PluginReconnected])
  );

  test("ignore further connect after re-activated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(pluginDefinition),
      PluginDeactivated,
      PluginActivated,
    ])
    |> whenCmd(ConnectPlugin(pluginDefinition))
    |> thenEvents([])
  );
});
