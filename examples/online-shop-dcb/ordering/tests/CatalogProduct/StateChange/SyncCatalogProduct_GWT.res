@@reventless.gwt

open OrderingExamples

describe("SyncCatalogProduct StateChangeSlice", () => {
  // scenario-id: 7aa368ea-aa0c-4643-9ac1-73fa767d66ee
  test("SyncNewProduct produces CatalogProductSynced", () =>
    givenEvents([])
    ->whenCmd(SyncNewProduct({productId: p1, name: laptop, price: 999.99}))
    ->thenEvent(CatalogProductSynced({productId: p1, name: laptop, price: 999.99}))
  )

  // scenario-id: ec4e7784-783e-4b2c-855c-d2c111333658
  test("ChangeSyncedPrice produces CatalogProductPriceChanged", () =>
    givenEvents([CatalogProductSynced({name: laptop, price: 999.99})])
    ->whenCmd(ChangeSyncedPrice({productId: p1, price: 899.99}))
    ->thenEvent(CatalogProductPriceChanged({productId: p1, price: 899.99}))
  )

  // scenario-id: 20c38820-28d3-4fb4-b9c6-64000e089de9
  test("re-syncing identical product data produces no events (idempotent)", () =>
    givenEvents([CatalogProductSynced({name: laptop, price: 999.99})])
    ->whenCmd(SyncNewProduct({productId: p1, name: laptop, price: 999.99}))
    ->thenNoEvent
  )

  // scenario-id: 9d1cebd5-19ce-4352-905f-00353c078b9b
  test("re-applying the current price produces no events (idempotent)", () =>
    givenEvents([CatalogProductSynced({name: laptop, price: 999.99})])
    ->whenCmd(ChangeSyncedPrice({productId: p1, price: 999.99}))
    ->thenNoEvent
  )
})
