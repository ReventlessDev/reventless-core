@@reventless.gwt

open CatalogExamples

describe("ChangeProductDescription StateChangeSlice", () => {
  // scenario-id: 0d389e6d-884a-46a4-afff-7e548f7263fc
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductDescription({productId: p1, description: anyDescription}))
    ->thenError(ProductNotFound)
  )

  // scenario-id: 2f663e70-7e0e-4427-8b64-9998ac13d868
  test("existing product produces ProductDescriptionChanged", () =>
    givenEvents([ProductAdded({description: laptopDescription})])
    ->whenCmd(ChangeProductDescription({productId: p1, description: highEndLaptop}))
    ->thenEvent(ProductDescriptionChanged({productId: p1, description: highEndLaptop}))
  )

  // scenario-id: 0af4afc8-a4c5-41de-a36e-9395cca2c1f8
  test("same description produces no events (idempotent)", () =>
    givenEvents([ProductAdded({description: laptopDescription})])
    ->whenCmd(ChangeProductDescription({productId: p1, description: laptopDescription}))
    ->thenNoEvent
  )

  // scenario-id: 5628b864-63f2-4dc4-af5b-c1b7d63e3b2d
  test("describing an archived product is allowed", () =>
    givenEvents([ProductAdded({description: laptopDescription}), ProductArchived])
    ->whenCmd(ChangeProductDescription({productId: p1, description: highEndLaptop}))
    ->thenEvent(ProductDescriptionChanged({productId: p1, description: highEndLaptop}))
  )

  // scenario-id: 126a6086-521f-4f51-b656-d106c11949d8
  test("describing a discontinued product is refused", () =>
    givenEvents([ProductAdded({description: laptopDescription}), ProductDiscontinued])
    ->whenCmd(ChangeProductDescription({productId: p1, description: highEndLaptop}))
    ->thenError(ProductIsDiscontinued)
  )
})
