@@reventless.gwt

describe("ChangeProductPrice StateChangeSlice", () => {
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductPrice({productId: "p1", price: 1.0}))
    ->thenError(ProductNotFound)
  )

  test("existing product produces ProductPriceChanged", () =>
    givenEvents([ProductAdded({price: 999.99})])
    ->whenCmd(ChangeProductPrice({productId: "p1", price: 899.99}))
    ->thenEvent(ProductPriceChanged({productId: "p1", price: 899.99}))
  )

  test("same price produces no events (idempotent)", () =>
    givenEvents([ProductAdded({price: 999.99})])
    ->whenCmd(ChangeProductPrice({productId: "p1", price: 999.99}))
    ->thenNoEvent
  )
})
