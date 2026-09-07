@@reventless.gwt

describe("AddProduct StateChangeSlice", () => {
  test("empty event log produces ProductAdded", () =>
    givenEvents([])
    ->whenCmd(AddProduct({productId: "p1", name: "Laptop", description: "x", price: 999.99}))
    ->thenEvent(ProductAdded({productId: "p1", name: "Laptop", description: "x", price: 999.99}))
  )

  test("existing product returns ProductAlreadyExists", () =>
    givenEvents([ProductAdded])
    ->whenCmd(AddProduct({productId: "p1", name: "Laptop", description: "x", price: 999.99}))
    ->thenError(ProductAlreadyExists)
  )
})
