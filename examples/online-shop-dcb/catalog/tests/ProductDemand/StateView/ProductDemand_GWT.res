@@reventless.gwt

describe("ProductDemand StateViewSlice", () => {
  test("ProductAdded initialises a row with orderCount = 0", () =>
    givenEvents([])
    ->whenEvent(ProductAdded({productId: "p1", name: "Laptop"}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", orderCount: 0})
  )

  test("ProductDemandRecorded increments orderCount", () =>
    givenEvents([ProductAdded({productId: "p1", name: "Laptop"})])
    ->whenEvent(ProductDemandRecorded({productId: "p1"}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", orderCount: 1})
  )

  test("ProductDemandRevoked decrements orderCount", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop"}),
      ProductDemandRecorded({productId: "p1"}),
      ProductDemandRecorded({productId: "p1"}),
    ])
    ->whenEvent(ProductDemandRevoked({productId: "p1"}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", orderCount: 1})
  )

  test("ProductDemandRevoked clamps orderCount at zero", () =>
    givenEvents([ProductAdded({productId: "p1", name: "Laptop"})])
    ->whenEvent(ProductDemandRevoked({productId: "p1"}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", orderCount: 0})
  )
})
