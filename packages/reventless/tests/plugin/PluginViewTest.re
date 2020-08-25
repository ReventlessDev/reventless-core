open Jest;

module PluginTest = Reventless.ViewTest.Make(PluginSpec, PluginView);
open PluginTest;
open PluginSpec;
open PluginFixture;
open Reventless.TestFixtures;

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
         extensionPoints: plugin1.extensionPoints,
         extensions: plugin1.extensions,
         status: Connected,
         since: context.meta.time,
       })
  );

  test("disconnected", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(plugin1)])
    |> whenEvent(PluginDisconnected)
    |> thenState({
         name: plugin1.name,
         version: plugin1.version,
         extensionPoints: plugin1.extensionPoints,
         extensions: plugin1.extensions,
         status: Disconnected,
         since: context.meta.time,
       })
  );

  test("deactivated", () =>
    givenEvents([UnknownPluginDetected, PluginConnected(plugin1)])
    |> whenEvent(PluginDeactivated)
    |> thenState({
         name: plugin1.name,
         version: plugin1.version,
         extensionPoints: plugin1.extensionPoints,
         extensions: plugin1.extensions,
         status: Inactive,
         since: context.meta.time,
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
         extensionPoints: plugin1.extensionPoints,
         extensions: plugin1.extensions,
         status: Disconnected,
         since: context.meta.time,
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
         extensionPoints: plugin1.extensionPoints,
         extensions: plugin1.extensions,
         status: Connected,
         since: context.meta.time,
       })
  );
});
