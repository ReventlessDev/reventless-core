open Jest;

module PluginTest = Reventless.ViewTest.Make(PluginSpec, PluginView);
open PluginTest;
open PluginSpec;
open PluginFixture;

describe("Plugin: View", () => {
  test("detected", () =>
    givenEvents([]) |> whenEvent(UnknownPluginDetected) |> thenNoState
  );

  test("already detected", () =>
    givenEvents([UnknownPluginDetected])
    |> whenEvent(UnknownPluginDetected)
    |> thenNoState
  );

  test("connected", () =>
    givenEvents([UnknownPluginDetected])
    |> whenEvent(PluginConnected(plugin1))
    |> thenState({
         name: plugin1.name,
         version: plugin1.version,
         status: Connected,
         extensionPoints: plugin1.extensionPoints,
         extensions: plugin1.extensions,
       })
  );

  test("disconnected", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(plugin1)])
    |> whenEvent(PluginDisconnected)
    |> thenState({
         name: plugin1.name,
         version: plugin1.version,
         status: Disconnected,
         extensionPoints: plugin1.extensionPoints,
         extensions: plugin1.extensions,
       })
  );

  test("deactivated", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(plugin1)])
    |> whenEvent(PluginDeactivated)
    |> thenState({
         name: plugin1.name,
         version: plugin1.version,
         status: Inactive,
         extensionPoints: plugin1.extensionPoints,
         extensions: plugin1.extensions,
       })
  );

  test("activated", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDeactivated,
    ])
    |> whenEvent(PluginActivated)
    |> thenState({
         name: plugin1.name,
         version: plugin1.version,
         status: Disconnected,
         extensionPoints: plugin1.extensionPoints,
         extensions: plugin1.extensions,
       })
  );

  test("re-connected after activation", () =>
    givenEvents([
      UnknownPluginDetected,
      PluginConnected(plugin1),
      PluginDeactivated,
      PluginActivated,
    ])
    |> whenEvent(PluginConnected(plugin1))
    |> thenState({
         name: plugin1.name,
         version: plugin1.version,
         status: Connected,
         extensionPoints: plugin1.extensionPoints,
         extensions: plugin1.extensions,
       })
  );
});
