open Jest;

module PluginTest =
  Reventless.BehaviourTest.Make(PluginSpec, PluginBehaviour);
open PluginTest;
open PluginSpec;
open PluginFixture;

describe("Plugin Aggregate", () => {
  test("detected", () =>
    givenEvents([])
    |> whenCmd(Heartbeat)
    |> thenEvents([UnknownPluginDetected])
  );

  test("already detected", () =>
    givenEvents([UnknownPluginDetected])
    |> whenCmd(Heartbeat)
    |> thenEvents([])
  );

  test("connected", () =>
    givenEvents([UnknownPluginDetected])
    |> whenCmd(ConnectPlugin(plugin1))
    |> thenEvents([PluginConnected(plugin1)])
  );

  test("disconnected", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(plugin1)])
    |> whenCmd(DisconnectPlugin)
    |> thenEvents([PluginDisconnected])
  );

  test("deactivated", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(plugin1)])
    |> whenCmd(DeactivatePlugin)
    |> thenEvents([PluginDeactivated])
  );

  test("activated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDeactivated,
    ])
    |> whenCmd(ActivatePlugin)
    |> thenEvents([PluginActivated])
  );

  test("re-detected after activation", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDeactivated,
      PluginActivated,
    ])
    |> whenCmd(Heartbeat)
    |> thenEvents([])
  );

  test("re-connected after activation", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDeactivated,
      PluginActivated,
    ])
    |> whenCmd(ConnectPlugin(plugin1))
    |> thenEvents([PluginConnected(plugin1)])
  );
});
