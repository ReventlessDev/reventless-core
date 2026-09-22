@@reventless.gwt

open CatalogExamples

describe("ChangeProductPrice StateChangeSlice", () => {
  // scenario-id: 4aef7c4c-75c8-4de7-936a-cbfea2782054
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductPrice({productId: p1, price: 899.99}))
    ->thenError(ProductNotFound)
  )

  // scenario-id: 7c6d3917-6dd1-4054-9cca-f50e55af3dcb
  test("existing product produces ProductPriceChanged", () =>
    givenEvents([ProductAdded({price: 999.99})])
    ->whenCmd(ChangeProductPrice({productId: p1, price: 899.99}))
    ->thenEvent(ProductPriceChanged({productId: p1, price: 899.99}))
  )

  // scenario-id: 1595706d-9e7d-44fb-8886-5ed328f695f9
  test("same price produces no events (idempotent)", () =>
    givenEvents([ProductAdded({price: 999.99})])
    ->whenCmd(ChangeProductPrice({productId: p1, price: 999.99}))
    ->thenNoEvent
  )
})
