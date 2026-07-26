@@reventless.gwt

describe("ChangeProductImage StateChangeSlice", () => {
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductImage({productId: "p1", imageUrl: "https://example.com/p1.jpg"}))
    ->thenError(ProductNotFound)
  )

  test("existing product produces ProductImageChanged", () =>
    givenEvents([ProductAdded({imageUrl: "https://example.com/p1.jpg"})])
    ->whenCmd(ChangeProductImage({productId: "p1", imageUrl: "https://example.com/p1-new.jpg"}))
    ->thenEvent(ProductImageChanged({productId: "p1", imageUrl: "https://example.com/p1-new.jpg"}))
  )

  test("same image produces no events (idempotent)", () =>
    givenEvents([ProductAdded({imageUrl: "https://example.com/p1.jpg"})])
    ->whenCmd(ChangeProductImage({productId: "p1", imageUrl: "https://example.com/p1.jpg"}))
    ->thenNoEvent
  )
})
