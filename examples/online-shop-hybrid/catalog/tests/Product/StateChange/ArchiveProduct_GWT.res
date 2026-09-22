@@reventless.gwt

open CatalogExamples

describe("ArchiveProduct StateChangeSlice", () => {
  // scenario-id: 7eecf512-fcb7-4e84-a7e7-54e0340903ee
  test("archive on non-existent product returns ProductNotFound", () =>
    givenEvents([])->whenCmd(ArchiveProduct({productId: p1}))->thenError(ProductNotFound)
  )

  // scenario-id: 1a2f2f54-116d-4cec-8ebe-4ec790712a08
  test("archive on a listed product produces ProductArchived", () =>
    givenEvents([ProductAdded])
    ->whenCmd(ArchiveProduct({productId: p1}))
    ->thenEvent(ProductArchived({productId: p1}))
  )

  // scenario-id: 0ce765c1-92d8-4d1c-afe6-09b7ee4695f3
  test("archive on an archived product produces no events (idempotent)", () =>
    givenEvents([ProductAdded, ProductArchived])
    ->whenCmd(ArchiveProduct({productId: p1}))
    ->thenNoEvent
  )

  // Not idempotent and not allowed: archiving out of `Discontinued` would move
  // the row back to a reversible state, which is the one thing the second
  // retirement exists to say it is not.
  // scenario-id: 8dd2ab04-aef5-4435-8953-25acf6d44d5a
  test("archive on a discontinued product is refused", () =>
    givenEvents([ProductAdded, ProductDiscontinued])
    ->whenCmd(ArchiveProduct({productId: p1}))
    ->thenError(ProductIsDiscontinued)
  )
})
