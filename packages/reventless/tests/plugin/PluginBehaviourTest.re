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
    |> whenCmd(ConnectPlugin(plugin1))
    |> thenEvents([PluginConnected(plugin1)])
  );

  test("ignored further connect when connected", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(plugin1)])
    |> whenCmd(ConnectPlugin(plugin1))
    |> thenEvents([])
  );

  test("disconnected", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(plugin1)])
    |> whenCmd(DisconnectPlugin)
    |> thenEvents([PluginDisconnected])
  );

  test("re-connected by heartbeat", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDisconnected,
    ])
    |> whenCmd(Heartbeat)
    |> thenEvents([PluginReconnected])
  );

  test("ignore further connect when disconnected", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDisconnected,
    ])
    |> whenCmd(ConnectPlugin(plugin1))
    |> thenEvents([])
  );

  test("deactivated", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(plugin1)])
    |> whenCmd(DeactivatePlugin)
    |> thenEvents([PluginDeactivated])
  );

  test("deactivated when disconnected", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDisconnected,
    ])
    |> whenCmd(DeactivatePlugin)
    |> thenEvents([PluginDeactivated])
  );

  test("re-activated after deactivated when disconnected", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDisconnected,
      PluginDeactivated,
    ])
    |> whenCmd(ActivatePlugin)
    |> thenEvents([PluginActivated])
  );

  test("ignore further connect when inactive", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDeactivated,
    ])
    |> whenCmd(ConnectPlugin(plugin1))
    |> thenEvents([])
  );

  test("re-activated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDeactivated,
    ])
    |> whenCmd(ActivatePlugin)
    |> thenEvents([PluginActivated])
  );

  test("re-connected by heartbeat after re-activated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDeactivated,
      PluginActivated,
    ])
    |> whenCmd(Heartbeat)
    |> thenEvents([PluginReconnected])
  );

  test("ignore further connect after re-activated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDeactivated,
      PluginActivated,
    ])
    |> whenCmd(ConnectPlugin(plugin1))
    |> thenEvents([])
  );
});
