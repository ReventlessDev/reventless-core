@@reventless.gwt

open Catalog_Examples

describe("ChangeProductName StateChangeSlice", () => {
  // scenario-id: 1836eaae-15ab-4723-9347-b8b181afefa9
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductName({productId: p1, name: gamingLaptop}))
    ->thenError(ProductNotFound)
  )

  // scenario-id: 1ebf3a47-eb7a-460d-84f2-7642855634c9
  test("existing product produces ProductNameChanged", () =>
    givenEvents([ProductAdded({name: laptop})])
    ->whenCmd(ChangeProductName({productId: p1, name: gamingLaptop}))
    ->thenEvent(ProductNameChanged({productId: p1, name: gamingLaptop}))
  )

  // scenario-id: b0f1d85f-8653-4061-adc2-ac1711da38f9
  test("same name produces no events (idempotent)", () =>
    givenEvents([ProductAdded({name: laptop})])
    ->whenCmd(ChangeProductName({productId: p1, name: laptop}))
    ->thenNoEvent
  )

  // scenario-id: 3d0dbd49-25ba-451e-8d4d-6c241a8f26b8
  test("renaming an archived product is allowed", () =>
    givenEvents([ProductAdded({name: laptop}), ProductArchived])
    ->whenCmd(ChangeProductName({productId: p1, name: gamingLaptop}))
    ->thenEvent(ProductNameChanged({productId: p1, name: gamingLaptop}))
  )

  // scenario-id: bb00f181-2b2b-4760-bf7f-e7c0648ff648
  test("renaming a discontinued product is refused", () =>
    givenEvents([ProductAdded({name: laptop}), ProductDiscontinued])
    ->whenCmd(ChangeProductName({productId: p1, name: gamingLaptop}))
    ->thenError(ProductIsDiscontinued)
  )
})
