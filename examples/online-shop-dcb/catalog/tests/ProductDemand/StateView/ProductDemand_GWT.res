@@reventless.gwt

open Catalog_Examples

describe("ProductDemand StateViewSlice", () => {
  // scenario-id: b2c9051d-6f80-4936-8bf1-52e57f43f1d5
  test("ProductAdded initialises a row with orderCount = 0", () =>
    givenEvents([])
    ->whenEvent(ProductAdded({productId: p1, name: laptop}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, orderCount: 0})
  )

  // scenario-id: 6f0ddd23-5af9-4b66-8035-a5c104244bd9
  test("ProductDemandRecorded increments orderCount", () =>
    givenEvents([ProductAdded({productId: p1, name: laptop})])
    ->whenEvent(ProductDemandRecorded({productId: p1}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, orderCount: 1})
  )

  // scenario-id: cfd0f93e-044a-4d0e-9f98-b4d50c4e5cfc
  test("ProductDemandRevoked decrements orderCount", () =>
    givenEvents([
      ProductAdded({productId: p1, name: laptop}),
      ProductDemandRecorded({productId: p1}),
      ProductDemandRecorded({productId: p1}),
    ])
    ->whenEvent(ProductDemandRevoked({productId: p1}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, orderCount: 1})
  )

  // scenario-id: d2e89076-a09d-488f-85b1-b4e303c80c00
  test("ProductDemandRevoked clamps orderCount at zero", () =>
    givenEvents([ProductAdded({productId: p1, name: laptop})])
    ->whenEvent(ProductDemandRevoked({productId: p1}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, orderCount: 0})
  )
})
