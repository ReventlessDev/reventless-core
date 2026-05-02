@@reventless.gwt

describe("Products StateViewSliceStream", () => {
  test("ProductAdded creates a row", () =>
    givenEvents([])
    ->whenEvent(ProductAdded({productId: "p1", name: "Laptop", description: "x", price: 999.99}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "x", price: 999.99},
    )
  )

  test("ProductNameChanged updates the name", () =>
    givenEvents([ProductAdded({productId: "p1", name: "Laptop", description: "x", price: 999.99})])
    ->whenEvent(ProductNameChanged({productId: "p1", name: "Gaming Laptop"}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Gaming Laptop", description: "x", price: 999.99},
    )
  )

  test("ProductDescriptionChanged updates the description", () =>
    givenEvents([ProductAdded({productId: "p1", name: "Laptop", description: "x", price: 999.99})])
    ->whenEvent(ProductDescriptionChanged({productId: "p1", description: "high-end"}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "high-end", price: 999.99},
    )
  )

  test("ProductPriceChanged updates the price", () =>
    givenEvents([ProductAdded({productId: "p1", name: "Laptop", description: "x", price: 999.99})])
    ->whenEvent(ProductPriceChanged({productId: "p1", price: 899.99}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "x", price: 899.99},
    )
  )
})
