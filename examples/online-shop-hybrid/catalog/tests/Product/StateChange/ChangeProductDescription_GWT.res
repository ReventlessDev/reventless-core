@@reventless.gwt

describe("ChangeProductDescription StateChangeSlice", () => {
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductDescription({productId: "p1", description: "x"}))
    ->thenError(ProductNotFound)
  )

  test("existing product produces ProductDescriptionChanged", () =>
    givenEvents([ProductAdded({description: "A laptop"})])
    ->whenCmd(ChangeProductDescription({productId: "p1", description: "high-end laptop"}))
    ->thenEvent(ProductDescriptionChanged({productId: "p1", description: "high-end laptop"}))
  )

  test("same description produces no events (idempotent)", () =>
    givenEvents([ProductAdded({description: "A laptop"})])
    ->whenCmd(ChangeProductDescription({productId: "p1", description: "A laptop"}))
    ->thenNoEvent
  )

  test("describing an archived product is allowed", () =>
    givenEvents([ProductAdded({description: "A laptop"}), ProductArchived])
    ->whenCmd(ChangeProductDescription({productId: "p1", description: "high-end laptop"}))
    ->thenEvent(ProductDescriptionChanged({productId: "p1", description: "high-end laptop"}))
  )

  test("describing a discontinued product is refused", () =>
    givenEvents([ProductAdded({description: "A laptop"}), ProductDiscontinued])
    ->whenCmd(ChangeProductDescription({productId: "p1", description: "high-end laptop"}))
    ->thenError(ProductIsDiscontinued)
  )
})
