@@reventless.gwt

open Catalog_Examples

describe("ProductDemand StateViewSliceStream", () => {
  // scenario-id: f88b6a22-6cd2-463b-a5d1-a46a041cae23
  test("ProductAdded initialises a row with orderCount = 0", () =>
    givenEvents([])
    ->whenEvent(ProductAdded({productId: p1, name: laptop, categoryId: cat1}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, categoryId: cat1, orderCount: 0})
  )

  // scenario-id: e4e9df0f-d160-4b8a-a4be-d6b10ad8ae82
  test("ProductDemandRecorded increments orderCount", () =>
    givenEvents([ProductAdded({productId: p1, name: laptop, categoryId: cat1})])
    ->whenEvent(ProductDemandRecorded({productId: p1}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, categoryId: cat1, orderCount: 1})
  )

  // scenario-id: 25dc0fb2-3aa5-4871-b83a-87274f9e4f2f
  test("ProductDemandRevoked decrements orderCount", () =>
    givenEvents([
      ProductAdded({productId: p1, name: laptop, categoryId: cat1}),
      ProductDemandRecorded({productId: p1}),
      ProductDemandRecorded({productId: p1}),
    ])
    ->whenEvent(ProductDemandRevoked({productId: p1}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, categoryId: cat1, orderCount: 1})
  )

  // scenario-id: 3e4ad8a6-9f87-4df1-b2e1-4346c65ce3ad
  test("ProductDemandRevoked clamps orderCount at zero", () =>
    givenEvents([ProductAdded({productId: p1, name: laptop, categoryId: cat1})])
    ->whenEvent(ProductDemandRevoked({productId: p1}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, categoryId: cat1, orderCount: 0})
  )
})
