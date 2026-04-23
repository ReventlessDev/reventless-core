open ReventlessCore
open PluginSpec
open PluginFixtures
module UIFragmentRegistryProjectionTest = ReventlessGwt.Projection_GWT.Make(
  UIFragmentRegistryProjection.UIFragmentRegistryMapping,
)
open UIFragmentRegistryProjectionTest

let registeredState: UIFragmentRegistryReadModelSpec.state = {
  pluginId: ReventlessGwt.TestFixtures.id,
  remoteEntryUrl: uiManifest.remoteEntryUrl,
  panels: uiManifest.panels,
  pages: uiManifest.pages,
  registeredAt: ReventlessGwt.TestFixtures.meta.time,
  updatedAt: ReventlessGwt.TestFixtures.meta.time,
}

let updatedManifest: Reventless.Plugin.uiFragmentManifest = {
  remoteEntryUrl: "https://cdn.example.com/plugin@2.0/remoteEntry.js",
  panels: [],
  pages: [],
}

describe("UIFragmentRegistryProjection:", () => {
  test("UIFragmentRegistered creates entry", () =>
    givenEvents([])
    ->whenEvent(UIFragmentRegistered({pluginId: pluginDefinition.id, manifest: uiManifest}))
    ->thenState(registeredState)
  )

  test("UIFragmentUpdated updates manifest fields", () =>
    givenEvents([UIFragmentRegistered({pluginId: pluginDefinition.id, manifest: uiManifest})])
    ->whenEvent(
      UIFragmentUpdated({
        pluginId: pluginDefinition.id,
        previousManifest: uiManifest,
        newManifest: updatedManifest,
      }),
    )
    ->thenState({
      ...registeredState,
      remoteEntryUrl: updatedManifest.remoteEntryUrl,
      panels: updatedManifest.panels,
      pages: updatedManifest.pages,
      updatedAt: ReventlessGwt.TestFixtures.meta.time,
    })
  )

  test("UIFragmentDeregistered removes entry", () =>
    givenEvents([UIFragmentRegistered({pluginId: pluginDefinition.id, manifest: uiManifest})])
    ->whenEvent(UIFragmentDeregistered({pluginId: pluginDefinition.id}))
    ->thenNoState
  )

  test("Connected is ignored", () =>
    givenEvents([UIFragmentRegistered({pluginId: pluginDefinition.id, manifest: uiManifest})])
    ->whenEvent(Connected(pluginDefinition))
    ->thenState(registeredState)
  )

  test("Disconnected is ignored", () =>
    givenEvents([UIFragmentRegistered({pluginId: pluginDefinition.id, manifest: uiManifest})])
    ->whenEvent(Disconnected(pluginDefinition))
    ->thenState(registeredState)
  )

  test("UnknownPluginDetected is ignored", () =>
    givenEvents([UIFragmentRegistered({pluginId: pluginDefinition.id, manifest: uiManifest})])
    ->whenEvent(UnknownPluginDetected)
    ->thenState(registeredState)
  )
})
