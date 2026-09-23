@@reventless.gwt

open Catalog_Examples

// The modelling claim that makes the two retired states worth having, asserted
// rather than left to a comment: one withdrawal can be undone and the other
// cannot. The declared edge is the framework half and is covered elsewhere; this
// pins the domain half, so a later edit cannot quietly make `Discontinued`
// reversible.
describe("UnarchiveProduct StateChangeSlice", () => {
  // scenario-id: 1749c448-0106-4892-856f-1286b25c289b
  test("unarchive on non-existent product returns ProductNotFound", () =>
    givenEvents([])->whenCmd(UnarchiveProduct({productId: p1}))->thenError(ProductNotFound)
  )

  // scenario-id: 68fa3db7-0a3f-4eeb-aae5-728b3ae67a16
  test("unarchive on an archived product produces ProductUnarchived", () =>
    givenEvents([ProductAdded, ProductArchived])
    ->whenCmd(UnarchiveProduct({productId: p1}))
    ->thenEvent(ProductUnarchived({productId: p1}))
  )

  // scenario-id: bad1c923-9ceb-4b20-b7f7-5840c9a2d37c
  test("unarchive on a listed product produces no events (idempotent)", () =>
    givenEvents([ProductAdded])->whenCmd(UnarchiveProduct({productId: p1}))->thenNoEvent
  )

  // The other half of the pair, and the assertion the whole two-state model
  // rests on: a discontinued product has no way back.
  // scenario-id: 9e4b2b50-7b33-4737-a8eb-497f6ceed859
  test("unarchive on a discontinued product is refused", () =>
    givenEvents([ProductAdded, ProductDiscontinued])
    ->whenCmd(UnarchiveProduct({productId: p1}))
    ->thenError(ProductIsDiscontinued)
  )

  // And it stays refused after a trip through the archive, so the refusal is
  // about the state the product is in rather than about how it got there.
  // scenario-id: 5c8b056f-a908-4126-823d-6547d69f04f0
  test("and stays refused for a product discontinued out of the archive", () =>
    givenEvents([ProductAdded, ProductArchived, ProductDiscontinued])
    ->whenCmd(UnarchiveProduct({productId: p1}))
    ->thenError(ProductIsDiscontinued)
  )
})
