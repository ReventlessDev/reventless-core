open PluginSpec
open PluginFixtures
module PluginTest = BehaviourTest.Make(PluginSpec, PluginBehaviour)
open PluginTest

describe("PluginBehaviour:", () => {
  test("Heartbeat (first)", () =>
    givenEvents(list{})->whenCmd(Heartbeat)->thenEvents(list{UnknownPluginDetected})
  )

  test("Heartbeat (again)", () =>
    givenEvents(list{UnknownPluginDetected})
    ->whenCmd(Heartbeat)
    ->thenEvents(list{UnknownPluginDetected})
  )

  test("Heartbeat (connected)", () =>
    givenEvents(list{UnknownPluginDetected, Connected(pluginDefinition)})
    ->whenCmd(Heartbeat)
    ->thenEvents(list{})
  )

  test("Heartbeat (inactive)", () =>
    givenEvents(list{
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
    })
    ->whenCmd(Heartbeat)
    ->thenEvents(list{})
  )

  test("Connect", () =>
    givenEvents(list{UnknownPluginDetected})
    ->whenCmd(Connect(pluginDefinition))
    ->thenEvents(list{Connected(pluginDefinition)})
  )

  test("Connect (after multiple Heartbeats)", () =>
    givenEvents(list{UnknownPluginDetected, UnknownPluginDetected})
    ->whenCmd(Connect(pluginDefinition))
    ->thenEvents(list{Connected(pluginDefinition)})
  )

  test("Connect (again)", () =>
    givenEvents(list{UnknownPluginDetected, Connected(pluginDefinition)})
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(AlreadyConnected)
  )

  test("Disconnect", () =>
    givenEvents(list{UnknownPluginDetected, Connected(pluginDefinition)})
    ->whenCmd(Disconnect)
    ->thenEvents(list{Disconnected(pluginDefinition)})
  )

  test("Heartbeat (re-connect)", () =>
    givenEvents(list{
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
    })
    ->whenCmd(Heartbeat)
    ->thenEvents(list{Reconnected(pluginDefinition)})
  )

  test("Connect (disconnected)", () =>
    givenEvents(list{
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
    })
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(IsDisconnected)
  )

  test("Deactivate", () =>
    givenEvents(list{UnknownPluginDetected, Connected(pluginDefinition)})
    ->whenCmd(Deactivate)
    ->thenEvents(list{Deactivated(pluginDefinition)})
  )

  test("Deactivate (disconnected)", () =>
    givenEvents(list{
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
    })
    ->whenCmd(Deactivate)
    ->thenEvents(list{Deactivated(pluginDefinition)})
  )

  test("Activate (deactivated, disconnected)", () =>
    givenEvents(list{
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
      Deactivated(pluginDefinition),
    })
    ->whenCmd(Activate)
    ->thenEvents(list{Activated(pluginDefinition)})
  )

  test("Connect (inactive)", () =>
    givenEvents(list{
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
    })
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(IsInactive)
  )

  test("Activate again", () =>
    givenEvents(list{
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
    })
    ->whenCmd(Activate)
    ->thenEvents(list{Activated(pluginDefinition)})
  )

  test("Heartbeat (re-connected after re-activated)", () =>
    givenEvents(list{
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
      Activated(pluginDefinition),
    })
    ->whenCmd(Heartbeat)
    ->thenEvents(list{Reconnected(pluginDefinition)})
  )

  test("Connect (re-activated)", () =>
    givenEvents(list{
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
      Activated(pluginDefinition),
    })
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(IsDisconnected)
  )
})
