// StateViewSlice projection GWT for the UiFragments read side (replaces the old
// UIFragmentRegistryProjection over Plugin-aggregate events). Projects the UiFragmentRegistry
// slice's events into the manifest-per-plugin row that backs the Platform_UIFragments query.
open ReventlessCore
open Plugin_Fixtures

module Test = ReventlessGwt.Projection_GWT.Make(UiFragments, UiFragments_Projection)
open Test
open UiFragments

let manifest2: Reventless.Plugin.uiFragmentManifest = {
  remoteEntryUrl: "https://cdn.example.com/plugin@2.0/remoteEntry.js",
  panels: [],
  pages: [],
}

let registeredState: UiFragments.state = {
  pluginId: "p1",
  remoteEntryUrl: uiManifest.remoteEntryUrl,
  panels: uiManifest.panels,
  pages: uiManifest.pages,
  registeredAt: "t0",
  updatedAt: "t0",
}

describe("UiFragments StateViewSlice projection", () => {
  test("UiFragmentRegistered creates the row (registeredAt = updatedAt = event time)", () =>
    givenEvents([])
    ->whenEvent(UiFragmentRegistered({pluginId: "p1", manifest: uiManifest, at: "t0"}))
    ->thenStateWithId("p1", registeredState)
  )

  test("UiFragmentUpdated updates manifest fields + updatedAt, keeps registeredAt", () =>
    givenEvents([UiFragmentRegistered({pluginId: "p1", manifest: uiManifest, at: "t0"})])
    ->whenEvent(
      UiFragmentUpdated({pluginId: "p1", previousManifest: uiManifest, newManifest: manifest2, at: "t1"}),
    )
    ->thenStateWithId(
      "p1",
      {
        ...registeredState,
        remoteEntryUrl: manifest2.remoteEntryUrl,
        panels: manifest2.panels,
        pages: manifest2.pages,
        updatedAt: "t1",
      },
    )
  )

  test("UiFragmentDeregistered removes the row", () =>
    givenEvents([UiFragmentRegistered({pluginId: "p1", manifest: uiManifest, at: "t0"})])
    ->whenEvent(UiFragmentDeregistered({pluginId: "p1"}))
    ->thenNoState
  )
})
