@@reventless.gwt

let pid = CatalogSpec.ProductId.make

describe("ChangeProductName StateChangeSlice", () => {
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductName({productId: pid("p1"), name: "Gaming Laptop"}))
    ->thenError(ProductNotFound)
  )

  test("existing product produces ProductNameChanged", () =>
    givenEvents([ProductAdded({name: "Laptop"})])
    ->whenCmd(ChangeProductName({productId: pid("p1"), name: "Gaming Laptop"}))
    ->thenEvent(ProductNameChanged({productId: pid("p1"), name: "Gaming Laptop"}))
  )

  test("same name produces no events (idempotent)", () =>
    givenEvents([ProductAdded({name: "Laptop"})])
    ->whenCmd(ChangeProductName({productId: pid("p1"), name: "Laptop"}))
    ->thenNoEvent
  )
})
