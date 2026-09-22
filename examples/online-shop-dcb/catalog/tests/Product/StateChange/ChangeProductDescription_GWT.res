@@reventless.gwt

open CatalogExamples

describe("ChangeProductDescription StateChangeSlice", () => {
  // scenario-id: e43e3238-da0f-4686-8001-e01cd195fef0
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductDescription({productId: p1, description: highEnd}))
    ->thenError(ProductNotFound)
  )

  // scenario-id: 288053da-ef75-42a0-98e6-04e6981d3f95
  test("existing product produces ProductDescriptionChanged", () =>
    givenEvents([ProductAdded({description: laptopDescription})])
    ->whenCmd(ChangeProductDescription({productId: p1, description: "high-end laptop"}))
    ->thenEvent(ProductDescriptionChanged({productId: p1, description: "high-end laptop"}))
  )

  // scenario-id: 04a1f4af-5c0e-4cc0-9d99-21c2b41d9b34
  test("same description produces no events (idempotent)", () =>
    givenEvents([ProductAdded({description: laptopDescription})])
    ->whenCmd(ChangeProductDescription({productId: p1, description: laptopDescription}))
    ->thenNoEvent
  )
})
