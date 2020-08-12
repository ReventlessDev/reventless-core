open Jest;

module PluginTest =
  Reventless.BehaviourTest.Make(PluginSpec, PluginBehaviour);
open PluginTest;
open PluginSpec;
open PluginFixture;

describe("Plugin", () => {
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
    givenEvents([PluginConnected(plugin1)])
    |> whenCmd(DisconnectPlugin)
    |> thenEvents([PluginDisconnected])
  );
});
