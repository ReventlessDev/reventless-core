@@reventless.gwt

describe("ChangeProductName StateChangeSlice", () => {
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductName({productId: "p1", name: "Gaming Laptop"}))
    ->thenError(ProductNotFound)
  )

  test("existing product produces ProductNameChanged", () =>
    givenEvents([ProductAdded({name: "Laptop"})])
    ->whenCmd(ChangeProductName({productId: "p1", name: "Gaming Laptop"}))
    ->thenEvent(ProductNameChanged({productId: "p1", name: "Gaming Laptop"}))
  )

  test("same name produces no events (idempotent)", () =>
    givenEvents([ProductAdded({name: "Laptop"})])
    ->whenCmd(ChangeProductName({productId: "p1", name: "Laptop"}))
    ->thenNoEvent
  )
})
