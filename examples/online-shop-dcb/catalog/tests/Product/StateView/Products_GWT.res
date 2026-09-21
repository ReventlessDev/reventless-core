@@reventless.gwt

let pid = CatalogSpec.ProductId.make

describe("Products StateViewSlice", () => {
  test("ProductAdded creates a row", () =>
    givenEvents([])
    ->whenEvent(
      ProductAdded({productId: pid("p1"), name: "Laptop", description: "x", price: 999.99}),
    )
    ->thenStateWithId("p1", {productId: pid("p1"), name: "Laptop", description: "x", price: 999.99})
  )

  test("ProductNameChanged updates the name", () =>
    givenEvents([
      ProductAdded({productId: pid("p1"), name: "Laptop", description: "x", price: 999.99}),
    ])
    ->whenEvent(ProductNameChanged({productId: pid("p1"), name: "Gaming Laptop"}))
    ->thenStateWithId(
      "p1",
      {productId: pid("p1"), name: "Gaming Laptop", description: "x", price: 999.99},
    )
  )

  test("ProductDescriptionChanged updates the description", () =>
    givenEvents([
      ProductAdded({productId: pid("p1"), name: "Laptop", description: "x", price: 999.99}),
    ])
    ->whenEvent(ProductDescriptionChanged({productId: pid("p1"), description: "high-end"}))
    ->thenStateWithId(
      "p1",
      {productId: pid("p1"), name: "Laptop", description: "high-end", price: 999.99},
    )
  )

  test("ProductPriceChanged updates the price", () =>
    givenEvents([
      ProductAdded({productId: pid("p1"), name: "Laptop", description: "x", price: 999.99}),
    ])
    ->whenEvent(ProductPriceChanged({productId: pid("p1"), price: 899.99}))
    ->thenStateWithId("p1", {productId: pid("p1"), name: "Laptop", description: "x", price: 899.99})
  )
})
