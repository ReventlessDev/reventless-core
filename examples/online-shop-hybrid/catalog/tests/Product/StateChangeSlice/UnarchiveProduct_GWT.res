@@reventless.gwt

// The modelling claim that makes the two retired states worth having, asserted
// rather than left to a comment: one withdrawal can be undone and the other
// cannot. `@transition` is the framework half and is covered elsewhere; this
// pins the domain half, so a later edit cannot quietly make `Discontinued`
// reversible.
describe("UnarchiveProduct StateChangeSlice", () => {
  test("unarchive on non-existent product returns ProductNotFound", () =>
    givenEvents([])->whenCmd(UnarchiveProduct({productId: "p1"}))->thenError(ProductNotFound)
  )

  test("unarchive on an archived product produces ProductUnarchived", () =>
    givenEvents([ProductAdded, ProductArchived])
    ->whenCmd(UnarchiveProduct({productId: "p1"}))
    ->thenEvent(ProductUnarchived({productId: "p1"}))
  )

  test("unarchive on a listed product produces no events (idempotent)", () =>
    givenEvents([ProductAdded])->whenCmd(UnarchiveProduct({productId: "p1"}))->thenNoEvent
  )

  // The other half of the pair, and the assertion the whole two-state model
  // rests on: a discontinued product has no way back.
  test("unarchive on a discontinued product is refused", () =>
    givenEvents([ProductAdded, ProductDiscontinued])
    ->whenCmd(UnarchiveProduct({productId: "p1"}))
    ->thenError(ProductIsDiscontinued)
  )

  // And it stays refused after a trip through the archive, so the refusal is
  // about the state the product is in rather than about how it got there.
  test("and stays refused for a product discontinued out of the archive", () =>
    givenEvents([ProductAdded, ProductArchived, ProductDiscontinued])
    ->whenCmd(UnarchiveProduct({productId: "p1"}))
    ->thenError(ProductIsDiscontinued)
  )
})
