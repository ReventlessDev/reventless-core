@@reventless.gwt

let pid = CatalogSpec.ProductId.make
let cid = CategoryId.make

describe("ProductDemand StateViewSliceStream", () => {
  test("ProductAdded initialises a row with orderCount = 0", () =>
    givenEvents([])
    ->whenEvent(ProductAdded({productId: pid("p1"), name: "Laptop", categoryId: cid("cat1")}))
    ->thenStateWithId(
      "p1",
      {productId: pid("p1"), name: "Laptop", categoryId: cid("cat1"), orderCount: 0},
    )
  )

  test("ProductDemandRecorded increments orderCount", () =>
    givenEvents([ProductAdded({productId: pid("p1"), name: "Laptop", categoryId: cid("cat1")})])
    ->whenEvent(ProductDemandRecorded({productId: pid("p1")}))
    ->thenStateWithId(
      "p1",
      {productId: pid("p1"), name: "Laptop", categoryId: cid("cat1"), orderCount: 1},
    )
  )

  test("ProductDemandRevoked decrements orderCount", () =>
    givenEvents([
      ProductAdded({productId: pid("p1"), name: "Laptop", categoryId: cid("cat1")}),
      ProductDemandRecorded({productId: pid("p1")}),
      ProductDemandRecorded({productId: pid("p1")}),
    ])
    ->whenEvent(ProductDemandRevoked({productId: pid("p1")}))
    ->thenStateWithId(
      "p1",
      {productId: pid("p1"), name: "Laptop", categoryId: cid("cat1"), orderCount: 1},
    )
  )

  test("ProductDemandRevoked clamps orderCount at zero", () =>
    givenEvents([ProductAdded({productId: pid("p1"), name: "Laptop", categoryId: cid("cat1")})])
    ->whenEvent(ProductDemandRevoked({productId: pid("p1")}))
    ->thenStateWithId(
      "p1",
      {productId: pid("p1"), name: "Laptop", categoryId: cid("cat1"), orderCount: 0},
    )
  )
})
