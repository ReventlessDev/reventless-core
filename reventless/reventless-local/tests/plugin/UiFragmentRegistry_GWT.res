// StateChangeSlice GWT for the UiFragmentRegistry write side (the platform UI-fragment
// registry extracted off the Plugin aggregate — event-sourced-fragment-registries plan).
open ReventlessCore
open Plugin_Fixtures

module Test = ReventlessGwt.Behavior_GWT.Make(UiFragmentRegistry, UiFragmentRegistry_Behavior)
open Test
open UiFragmentRegistry

let manifest2: Reventless.Plugin.uiFragmentManifest = {
  remoteEntryUrl: "https://cdn.example.com/plugin@2.0/remoteEntry.js",
  panels: [],
  pages: [],
}

describe("UiFragmentRegistry StateChangeSlice", () => {
  test("register on empty state emits UiFragmentRegistered", () =>
    givenEvents([])
    ->whenCmd(RegisterUiFragment({pluginId: "p1", manifest: uiManifest, at: "t0"}))
    ->thenEvent(UiFragmentRegistered({pluginId: "p1", manifest: uiManifest, at: "t0"}))
  )

  test("re-registering an identical manifest is idempotent (no event)", () =>
    givenEvents([UiFragmentRegistered({pluginId: "p1", manifest: uiManifest, at: "t0"})])
    ->whenCmd(RegisterUiFragment({pluginId: "p1", manifest: uiManifest, at: "t1"}))
    ->thenNoEvent
  )

  test("registering a changed manifest emits UiFragmentUpdated", () =>
    givenEvents([UiFragmentRegistered({pluginId: "p1", manifest: uiManifest, at: "t0"})])
    ->whenCmd(RegisterUiFragment({pluginId: "p1", manifest: manifest2, at: "t1"}))
    ->thenEvent(
      UiFragmentUpdated({
        pluginId: "p1",
        previousManifest: uiManifest,
        newManifest: manifest2,
        at: "t1",
      }),
    )
  )

  test("deregister emits UiFragmentDeregistered", () =>
    givenEvents([UiFragmentRegistered({pluginId: "p1", manifest: uiManifest, at: "t0"})])
    ->whenCmd(DeregisterUiFragment({pluginId: "p1"}))
    ->thenEvent(UiFragmentDeregistered({pluginId: "p1"}))
  )

  test("deregistering an absent fragment is idempotent (no event)", () =>
    givenEvents([])
    ->whenCmd(DeregisterUiFragment({pluginId: "p1"}))
    ->thenNoEvent
  )
})
