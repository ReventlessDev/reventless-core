open ReventlessCore
open PluginSpec
open PluginFixtures
module PluginTest = ReventlessGwt.Behavior_GWT.Make(PluginSpec, PluginBehavior)
open PluginTest

describe("PluginBehavior:", () => {
  test("Heartbeat (first)", () =>
    givenEvents([])->whenCmd(Heartbeat)->thenEvents([UnknownPluginDetected])
  )

  test("Heartbeat (again)", () =>
    givenEvents([UnknownPluginDetected])->whenCmd(Heartbeat)->thenEvents([UnknownPluginDetected])
  )

  test("Heartbeat (connected)", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(Heartbeat)
    ->thenNoEvent
  )

  test("Heartbeat (inactive)", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition), Deactivated(pluginDefinition)])
    ->whenCmd(Heartbeat)
    ->thenNoEvent
  )

  test("Connect", () =>
    givenEvents([UnknownPluginDetected])
    ->whenCmd(Connect(pluginDefinition))
    ->thenEvents([Connected(pluginDefinition)])
  )

  test("Connect (after multiple Heartbeats)", () =>
    givenEvents([UnknownPluginDetected, UnknownPluginDetected])
    ->whenCmd(Connect(pluginDefinition))
    ->thenEvents([Connected(pluginDefinition)])
  )

  test("Connect (again)", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(AlreadyConnected)
  )

  test("Disconnect", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(Disconnect)
    ->thenEvents([Disconnected(pluginDefinition)])
  )

  test("Heartbeat (re-connect)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
    ])
    ->whenCmd(Heartbeat)
    ->thenEvents([Reconnected(pluginDefinition)])
  )

  test("Connect (disconnected)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
    ])
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(IsDisconnected)
  )

  test("Deactivate", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(Deactivate)
    ->thenEvents([Deactivated(pluginDefinition)])
  )

  test("Deactivate (disconnected)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
    ])
    ->whenCmd(Deactivate)
    ->thenEvents([Deactivated(pluginDefinition)])
  )

  test("Activate (deactivated, disconnected)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
      Deactivated(pluginDefinition),
    ])
    ->whenCmd(Activate)
    ->thenEvents([Activated(pluginDefinition)])
  )

  test("Connect (inactive)", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition), Deactivated(pluginDefinition)])
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(IsInactive)
  )

  test("Activate again", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition), Deactivated(pluginDefinition)])
    ->whenCmd(Activate)
    ->thenEvents([Activated(pluginDefinition)])
  )

  test("Heartbeat (re-connected after re-activated)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
      Activated(pluginDefinition),
    ])
    ->whenCmd(Heartbeat)
    ->thenEvents([Reconnected(pluginDefinition)])
  )

  test("Connect (re-activated)", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
      Activated(pluginDefinition),
    ])
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(IsDisconnected)
  )

  test("Connect (with UI fragments) emits UIFragmentRegistered", () =>
    givenEvents([UnknownPluginDetected])
    ->whenCmd(Connect(pluginDefinitionWithUI))
    ->thenEvents([
      Connected(pluginDefinitionWithUI),
      UIFragmentRegistered({pluginId: pluginDefinitionWithUI.id, manifest: uiManifest}),
    ])
  )

  test("Disconnect (with UI fragments) emits UIFragmentDeregistered", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinitionWithUI)])
    ->whenCmd(Disconnect)
    ->thenEvents([
      Disconnected(pluginDefinitionWithUI),
      UIFragmentDeregistered({pluginId: pluginDefinitionWithUI.id}),
    ])
  )

  test("Deactivate (connected, with UI fragments) emits UIFragmentDeregistered", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinitionWithUI)])
    ->whenCmd(Deactivate)
    ->thenEvents([
      Deactivated(pluginDefinitionWithUI),
      UIFragmentDeregistered({pluginId: pluginDefinitionWithUI.id}),
    ])
  )

  test("Heartbeat (re-connect with UI fragments) emits UIFragmentRegistered", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinitionWithUI),
      Disconnected(pluginDefinitionWithUI),
    ])
    ->whenCmd(Heartbeat)
    ->thenEvents([
      Reconnected(pluginDefinitionWithUI),
      UIFragmentRegistered({pluginId: pluginDefinitionWithUI.id, manifest: uiManifest}),
    ])
  )

  test("Deactivate (disconnected, with UI fragments) emits no UIFragmentDeregistered", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinitionWithUI),
      Disconnected(pluginDefinitionWithUI),
    ])
    ->whenCmd(Deactivate)
    ->thenEvents([Deactivated(pluginDefinitionWithUI)])
  )
})
