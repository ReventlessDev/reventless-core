@@reventless.gwt

let pid = CatalogSpec.ProductId.make

describe("SyncCatalogProduct StateChangeSlice", () => {
  test("SyncNewProduct produces CatalogProductSynced", () =>
    givenEvents([])
    ->whenCmd(SyncNewProduct({productId: pid("p1"), name: "Laptop", price: 999.99}))
    ->thenEvent(CatalogProductSynced({productId: pid("p1"), name: "Laptop", price: 999.99}))
  )

  test("ChangeSyncedPrice produces CatalogProductPriceChanged", () =>
    givenEvents([CatalogProductSynced({name: "Laptop", price: 999.99})])
    ->whenCmd(ChangeSyncedPrice({productId: pid("p1"), price: 899.99}))
    ->thenEvent(CatalogProductPriceChanged({productId: pid("p1"), price: 899.99}))
  )

  test("re-syncing identical product data produces no events (idempotent)", () =>
    givenEvents([CatalogProductSynced({name: "Laptop", price: 999.99})])
    ->whenCmd(SyncNewProduct({productId: pid("p1"), name: "Laptop", price: 999.99}))
    ->thenNoEvent
  )

  test("re-applying the current price produces no events (idempotent)", () =>
    givenEvents([CatalogProductSynced({name: "Laptop", price: 999.99})])
    ->whenCmd(ChangeSyncedPrice({productId: pid("p1"), price: 999.99}))
    ->thenNoEvent
  )
})
