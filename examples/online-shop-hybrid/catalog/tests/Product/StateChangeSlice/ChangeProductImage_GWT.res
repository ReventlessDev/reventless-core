@@reventless.gwt

describe("ChangeProductImage StateChangeSlice", () => {
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductImage({productId: "p1", productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}))
    ->thenError(ProductNotFound)
  )

  test("existing product produces ProductImageChanged", () =>
    givenEvents([ProductAdded({productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"})])
    ->whenCmd(ChangeProductImage({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-new.jpg"}))
    ->thenEvent(ProductImageChanged({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-new.jpg"}))
  )

  test("same image produces no events (idempotent)", () =>
    givenEvents([ProductAdded({productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"})])
    ->whenCmd(ChangeProductImage({productId: "p1", productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}))
    ->thenNoEvent
  )

  test("changing an archived product's image is allowed", () =>
    givenEvents([
      ProductAdded({productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}),
      ProductArchived,
    ])
    ->whenCmd(ChangeProductImage({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-new.jpg"}))
    ->thenEvent(ProductImageChanged({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-new.jpg"}))
  )

  test("changing a discontinued product's image is refused", () =>
    givenEvents([
      ProductAdded({productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}),
      ProductDiscontinued,
    ])
    ->whenCmd(ChangeProductImage({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-new.jpg"}))
    ->thenError(ProductIsDiscontinued)
  )
})
