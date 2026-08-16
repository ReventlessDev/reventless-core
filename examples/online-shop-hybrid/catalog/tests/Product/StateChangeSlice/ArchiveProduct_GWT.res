@@reventless.gwt

describe("ArchiveProduct StateChangeSlice", () => {
  test("archive on non-existent product returns ProductNotFound", () =>
    givenEvents([])->whenCmd(ArchiveProduct({productId: "p1"}))->thenError(ProductNotFound)
  )

  test("archive on a listed product produces ProductArchived", () =>
    givenEvents([ProductAdded])
    ->whenCmd(ArchiveProduct({productId: "p1"}))
    ->thenEvent(ProductArchived({productId: "p1"}))
  )

  test("archive on an archived product produces no events (idempotent)", () =>
    givenEvents([ProductAdded, ProductArchived])
    ->whenCmd(ArchiveProduct({productId: "p1"}))
    ->thenNoEvent
  )

  // Not idempotent and not allowed: archiving out of `Discontinued` would move
  // the row back to a reversible state, which is the one thing the second
  // retirement exists to say it is not.
  test("archive on a discontinued product is refused", () =>
    givenEvents([ProductAdded, ProductDiscontinued])
    ->whenCmd(ArchiveProduct({productId: "p1"}))
    ->thenError(ProductIsDiscontinued)
  )
})
