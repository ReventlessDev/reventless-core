@@reventless.gwt

describe("ProductDemand StateViewSliceStream", () => {
  test("ProductAdded initialises a row with orderCount = 0", () =>
    givenEvents([])
    ->whenEvent(ProductAdded({productId: "p1", name: "Laptop", categoryId: "cat1"}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", categoryId: "cat1", orderCount: 0})
  )

  test("ProductDemandRecorded increments orderCount", () =>
    givenEvents([ProductAdded({productId: "p1", name: "Laptop", categoryId: "cat1"})])
    ->whenEvent(ProductDemandRecorded({productId: "p1"}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", categoryId: "cat1", orderCount: 1})
  )

  test("ProductDemandRevoked decrements orderCount", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", categoryId: "cat1"}),
      ProductDemandRecorded({productId: "p1"}),
      ProductDemandRecorded({productId: "p1"}),
    ])
    ->whenEvent(ProductDemandRevoked({productId: "p1"}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", categoryId: "cat1", orderCount: 1})
  )

  test("ProductDemandRevoked clamps orderCount at zero", () =>
    givenEvents([ProductAdded({productId: "p1", name: "Laptop", categoryId: "cat1"})])
    ->whenEvent(ProductDemandRevoked({productId: "p1"}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", categoryId: "cat1", orderCount: 0})
  )
})
