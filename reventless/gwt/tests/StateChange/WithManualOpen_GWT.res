// Manual-open dedup verification for @@reventless.gwt companion fixtures.
//
// The sibling [WithManualOpen_Fixtures.res] exists AND the test body opens
// it manually. The PPX detects the existing open via [Util.has_open] and
// skips the duplicate injection — the file compiles without shadow warnings.

@@reventless.gwt

open WithManualOpen_Fixtures

describe("WithManualOpen (manual open not duplicated by PPX)", () => {
  test("manual open resolves fixture identifiers", () =>
    givenEvents([])
    ->whenCmd(addCategoryBooks)
    ->thenEvent((booksCategoryAdded :> event))
  )
})
