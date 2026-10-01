@@reventless.gwt

open Catalog_Examples

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

describe("Who may ArchiveProduct", () => {
  // scenario-id: ba1ecf0d-bb70-4164-ab63-b8b9ec2efe12
  test("a Merchandiser may archive a product", () =>
    givenEvents([ProductAdded])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(ArchiveProduct({productId: p1}))
    ->thenEvent(ProductArchived({productId: p1}))
  )

  // scenario-id: 6acabade-1b86-4686-b71c-e53d6d6d224f
  test("an Admin may archive a product", () =>
    givenEvents([ProductAdded])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(ArchiveProduct({productId: p1}))
    ->thenEvent(ProductArchived({productId: p1}))
  )

  // scenario-id: e446d059-9625-4e65-be56-e5e626ee2a17
  test("a shopper may not archive a product", () =>
    givenEvents([ProductAdded])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(ArchiveProduct({productId: p1}))
    ->thenRefused
  )

  // scenario-id: 683fa38d-fbca-4036-9e80-25531838f4ac
  test("an anonymous caller may not archive a product", () =>
    givenEvents([ProductAdded])
    ->asCaller(Caller.anonymous)
    ->whenCmd(ArchiveProduct({productId: p1}))
    ->thenRefused
  )
})
