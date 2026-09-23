@@reventless.gwt

open Catalog_Examples

describe("AddProduct StateChangeSlice", () => {
  // scenario-id: 87169cfc-9317-4591-b452-874e0fd5f6ad
  test("empty event log produces ProductAdded", () =>
    givenEvents([])
    ->whenCmd(AddProduct({productId: p1, name: laptop, description: anyDescription, price: 999.99}))
    ->thenEvent(
      ProductAdded({productId: p1, name: laptop, description: anyDescription, price: 999.99}),
    )
  )

  // scenario-id: 34a448fe-d2c7-4fcf-bc93-88534013321f
  test("existing product returns ProductAlreadyExists", () =>
    givenEvents([ProductAdded])
    ->whenCmd(AddProduct({productId: p1, name: laptop, description: anyDescription, price: 999.99}))
    ->thenError(ProductAlreadyExists)
  )
})
