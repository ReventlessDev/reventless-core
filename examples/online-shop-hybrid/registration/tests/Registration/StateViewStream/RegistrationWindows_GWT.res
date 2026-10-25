@@reventless.gwt

open Registration_Examples

// What a visitor may read about registration: whether a role is open, and until
// when. One row per role an administrator has said anything about; a role with
// no row is open.

let until = "2026-10-31T00:00:00.000Z"

describe("RegistrationWindows StateViewSliceStream", () => {
  // scenario-id: 7a4c2e9b-3d1f-4b6a-8e5c-2f0d9a1b3c4e
  test("a closed role has a closed row", () =>
    givenEvents([])
    ->whenEvent(RegistrationClosed({role: shopperName}))
    ->thenStateWithId(shopperName, {role: shopperName, isOpen: false})
  )

  // scenario-id: b5d3f1a7-8c2e-4d9b-a6f0-4e1c7b9d2a3f
  test("opening a role again shows it open, with its end", () =>
    givenEvents([RegistrationClosed({role: shopperName})])
    ->whenEvent(RegistrationOpened({role: shopperName, until}))
    ->thenStateWithId(shopperName, {role: shopperName, isOpen: true, until})
  )

  // scenario-id: c9e2a4d6-1f3b-4e7a-9c5d-8b0e2f4a6c1d
  test("a role nobody has said anything about has no row", () =>
    givenEvents([])->whenEvents([])->thenNoState
  )
})
