// Companion-fixtures auto-open verification test for @@reventless.gwt.
//
// Zero payload, no local module, no manual open. The PPX resolves:
//   - Kind from the folder segment "StateChange" -> StateChangeSlice
//   - Spec from the filename stem (strip "_GWT") -> WithFixtures
//   - Companion fixtures: sibling [WithFixtures_Fixtures.res] is detected on
//     disk, so the PPX emits both [open WithFixtures] and
//     [open WithFixtures_Fixtures] before the [include].
//
// The test body uses [addCategoryElectronics] / [electronicsCategoryAdded]
// unqualified — resolution only succeeds if the companion fixtures open was
// injected.

@@reventless.gwt

describe("WithFixtures StateChangeSlice (companion fixtures auto-open)", () => {
  test("uses companion fixtures unqualified", () =>
    givenEvents([])
    ->whenCmd(addCategoryElectronics)
    ->thenEvent((electronicsCategoryAdded :> event))
  )
})

