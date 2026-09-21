@@reventless.gwt

let pid = CatalogSpec.ProductId.make

describe("ProductDemand StateViewSlice", () => {
  test("ProductAdded initialises a row with orderCount = 0", () =>
    givenEvents([])
    ->whenEvent(ProductAdded({productId: pid("p1"), name: "Laptop"}))
    ->thenStateWithId("p1", {productId: pid("p1"), name: "Laptop", orderCount: 0})
  )

  test("ProductDemandRecorded increments orderCount", () =>
    givenEvents([ProductAdded({productId: pid("p1"), name: "Laptop"})])
    ->whenEvent(ProductDemandRecorded({productId: pid("p1")}))
    ->thenStateWithId("p1", {productId: pid("p1"), name: "Laptop", orderCount: 1})
  )

  test("ProductDemandRevoked decrements orderCount", () =>
    givenEvents([
      ProductAdded({productId: pid("p1"), name: "Laptop"}),
      ProductDemandRecorded({productId: pid("p1")}),
      ProductDemandRecorded({productId: pid("p1")}),
    ])
    ->whenEvent(ProductDemandRevoked({productId: pid("p1")}))
    ->thenStateWithId("p1", {productId: pid("p1"), name: "Laptop", orderCount: 1})
  )

  test("ProductDemandRevoked clamps orderCount at zero", () =>
    givenEvents([ProductAdded({productId: pid("p1"), name: "Laptop"})])
    ->whenEvent(ProductDemandRevoked({productId: pid("p1")}))
    ->thenStateWithId("p1", {productId: pid("p1"), name: "Laptop", orderCount: 0})
  )
})
