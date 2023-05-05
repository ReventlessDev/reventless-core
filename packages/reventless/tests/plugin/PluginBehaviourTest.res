open PluginSpec
open PluginFixtures
module PluginTest = BehaviourTest.Make(PluginSpec, PluginBehaviour)
open PluginTest

describe("PluginBehaviour:", () => {
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
})
