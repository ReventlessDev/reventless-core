@@reventless.gwt

open CatalogExamples

describe("Products StateViewSlice", () => {
  // scenario-id: cf0ca1ca-b80e-4d32-8c7c-0b02476b2b6c
  test("ProductAdded creates a row", () =>
    givenEvents([])
    ->whenEvent(
      ProductAdded({productId: p1, name: laptop, description: anyDescription, price: 999.99}),
    )
    ->thenStateWithId(
      "p1",
      {productId: p1, name: laptop, description: anyDescription, price: 999.99},
    )
  )

  // scenario-id: 0507cbde-2302-4142-9b4a-36b5f03f76d0
  test("ProductNameChanged updates the name", () =>
    givenEvents([
      ProductAdded({productId: p1, name: laptop, description: anyDescription, price: 999.99}),
    ])
    ->whenEvent(ProductNameChanged({productId: p1, name: gamingLaptop}))
    ->thenStateWithId(
      "p1",
      {productId: p1, name: gamingLaptop, description: anyDescription, price: 999.99},
    )
  )

  // scenario-id: f25ea437-a469-455b-bf6f-64b62ca4abf7
  test("ProductDescriptionChanged updates the description", () =>
    givenEvents([
      ProductAdded({productId: p1, name: laptop, description: anyDescription, price: 999.99}),
    ])
    ->whenEvent(ProductDescriptionChanged({productId: p1, description: highEnd}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, description: highEnd, price: 999.99})
  )

  // scenario-id: fc1bfcce-68e9-4258-85db-020a9f77679b
  test("ProductPriceChanged updates the price", () =>
    givenEvents([
      ProductAdded({productId: p1, name: laptop, description: anyDescription, price: 999.99}),
    ])
    ->whenEvent(ProductPriceChanged({productId: p1, price: 899.99}))
    ->thenStateWithId(
      "p1",
      {productId: p1, name: laptop, description: anyDescription, price: 899.99},
    )
  )
})
