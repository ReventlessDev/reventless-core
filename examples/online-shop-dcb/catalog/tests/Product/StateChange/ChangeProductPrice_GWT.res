@@reventless.gwt

let pid = CatalogSpec.ProductId.make

describe("ChangeProductPrice StateChangeSlice", () => {
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductPrice({productId: pid("p1"), price: 899.99}))
    ->thenError(ProductNotFound)
  )

  test("existing product produces ProductPriceChanged", () =>
    givenEvents([ProductAdded({price: 999.99})])
    ->whenCmd(ChangeProductPrice({productId: pid("p1"), price: 899.99}))
    ->thenEvent(ProductPriceChanged({productId: pid("p1"), price: 899.99}))
  )

  test("same price produces no events (idempotent)", () =>
    givenEvents([ProductAdded({price: 999.99})])
    ->whenCmd(ChangeProductPrice({productId: pid("p1"), price: 999.99}))
    ->thenNoEvent
  )
})
