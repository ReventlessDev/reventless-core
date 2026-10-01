@@reventless.gwt

open Catalog_Examples

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

describe("Who may ChangeProductDescription", () => {
  // scenario-id: 3a3ea812-a6ef-4a5e-9cc9-a326a5e360c5
  test("a Merchandiser may describe a product", () =>
    givenEvents([ProductAdded({description: laptopDescription})])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(ChangeProductDescription({productId: p1, description: highEndLaptop}))
    ->thenEvent(ProductDescriptionChanged({productId: p1, description: highEndLaptop}))
  )

  // scenario-id: bbe4ad6d-02d1-4ca0-87b9-8ee280f261f0
  test("an Admin may describe a product", () =>
    givenEvents([ProductAdded({description: laptopDescription})])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(ChangeProductDescription({productId: p1, description: highEndLaptop}))
    ->thenEvent(ProductDescriptionChanged({productId: p1, description: highEndLaptop}))
  )

  // scenario-id: f4dba59c-92e4-41a7-90e2-c75aec949db2
  test("a shopper may not describe a product", () =>
    givenEvents([ProductAdded({description: laptopDescription})])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(ChangeProductDescription({productId: p1, description: highEndLaptop}))
    ->thenRefused
  )

  // scenario-id: 34eb891c-0c5f-4b30-ba53-b89f48104840
  test("an anonymous caller may not describe a product", () =>
    givenEvents([ProductAdded({description: laptopDescription})])
    ->asCaller(Caller.anonymous)
    ->whenCmd(ChangeProductDescription({productId: p1, description: highEndLaptop}))
    ->thenRefused
  )
})
