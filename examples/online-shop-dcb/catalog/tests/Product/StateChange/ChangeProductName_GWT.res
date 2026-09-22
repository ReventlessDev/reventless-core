@@reventless.gwt

open CatalogExamples

describe("ChangeProductName StateChangeSlice", () => {
  // scenario-id: dcdba196-6b51-4147-9f0a-897174fe21c2
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductName({productId: p1, name: gamingLaptop}))
    ->thenError(ProductNotFound)
  )

  // scenario-id: 7f5a6d6f-0af2-4588-b9e1-5e35bf0f002d
  test("existing product produces ProductNameChanged", () =>
    givenEvents([ProductAdded({name: laptop})])
    ->whenCmd(ChangeProductName({productId: p1, name: gamingLaptop}))
    ->thenEvent(ProductNameChanged({productId: p1, name: gamingLaptop}))
  )

  // scenario-id: b2152e4d-809c-409c-91f8-90185c2d39b2
  test("same name produces no events (idempotent)", () =>
    givenEvents([ProductAdded({name: laptop})])
    ->whenCmd(ChangeProductName({productId: p1, name: laptop}))
    ->thenNoEvent
  )
})
