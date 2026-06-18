open ReventlessCore
open PluginSpec
open Plugin_Fixtures
module PluginsProjectionTest = ReventlessGwt.MultiSourceProjection_GWT.Make(PluginsProjection.PluginMapping)
open PluginsProjectionTest

// Current view (one row per plugin name). The displayed row tracks the current
// version (highest Connected); `otherConnectedVersions` lists the OTHER versions
// currently Connected (own version excluded) — used to recompute current during a
// deploy overlap, pruned the moment a version stops being Connected.

let supersededV1ByV2 = VersionSuperseded({
  supersededVersion: "1",
  supersededDefinition: pluginDefinition,
  newVersion: "2",
  newDefinition: pluginDefinitionV2,
})

describe("PluginsProjection:", () => {
  test("VersionDetected does not create a row", () =>
    givenEvents([])->whenEvent(VersionDetected("1"))->thenNoState
  )

  test("VersionConnected writes the current row", () =>
    givenEvents([])
    ->whenEvent(VersionConnected(pluginDefinition))
    ->thenState(state)
  )

  test("A higher VersionConnected becomes the current row (supersession)", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenEvent(VersionConnected(pluginDefinitionV2))
    ->thenState(display(pluginDefinitionV2, Connected, ["1"]))
  )

  test("A lower VersionConnected records status but keeps the higher current", () =>
    givenEvents([VersionConnected(pluginDefinitionV2)])
    ->whenEvent(VersionConnected(pluginDefinition))
    ->thenState(display(pluginDefinitionV2, Connected, ["1"]))
  )

  test("VersionSuperseded itself does not change the row", () =>
    givenEvents([VersionConnected(pluginDefinition)])->whenEvent(supersededV1ByV2)->thenState(state)
  )

  test("VersionDisconnected of the current flips its status", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenEvent(VersionDisconnected(pluginDefinition))
    ->thenState(display(pluginDefinition, Disconnected, []))
  )

  test("VersionPromoted rolls the current back to a lower live version", () =>
    givenEvents([
      VersionConnected(pluginDefinition),
      VersionConnected(pluginDefinitionV2),
      VersionDisconnected(pluginDefinitionV2),
    ])
    ->whenEvent(VersionPromoted(pluginDefinition))
    ->thenState(display(pluginDefinition, Connected, []))
  )

  test("VersionDeactivated of the current yields status Inactive", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenEvent(VersionDeactivated(pluginDefinition))
    ->thenState(display(pluginDefinition, Inactive, []))
  )

  test("VersionRetired of the current yields status Retired", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenEvent(VersionRetired(pluginDefinition))
    ->thenState(display(pluginDefinition, Retired, []))
  )

  test("UIFragmentRegistered is ignored by the current view", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenEvent(UIFragmentRegistered({pluginId: pluginDefinition.id, manifest: uiManifest}))
    ->thenState(state)
  )

  test("UIFragmentDeregistered is ignored by the current view", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenEvent(UIFragmentDeregistered({pluginId: pluginDefinition.id}))
    ->thenState(state)
  )

  test("IncompatiblePluginDetected leaves a connected row unchanged", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenEvent(IncompatiblePluginDetected(pluginDefinition))
    ->thenState(state)
  )

  test("IncompatiblePluginDetected on a never-seen plugin creates no row", () =>
    givenEvents([])->whenEvent(IncompatiblePluginDetected(pluginDefinition))->thenNoState
  )
})
