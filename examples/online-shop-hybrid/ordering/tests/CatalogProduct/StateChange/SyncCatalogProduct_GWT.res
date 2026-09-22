@@reventless.gwt

open OrderingExamples

// Prices are money, so a test writes the amount a person would say and converts
// it once. `ofMajor` scales by the currency's own exponent, which is what keeps
// the literal honest: 9.99 EUR is 999 cents, and the same call on a JPY price
// would scale by 1.

describe("SyncCatalogProduct StateChangeSlice", () => {
  // scenario-id: 8dfa1851-7779-4c9d-beeb-674e0664e16a
  test("SyncNewProduct produces CatalogProductSynced", () =>
    givenEvents([])
    ->whenCmd(SyncNewProduct({productId: p1, name: laptop, price: laptopPrice}))
    ->thenEvent(CatalogProductSynced({productId: p1, name: laptop, price: laptopPrice}))
  )

  // scenario-id: c160117a-1887-4d22-ae68-49751a19a632
  test("ChangeSyncedPrice produces CatalogProductPriceChanged", () =>
    givenEvents([CatalogProductSynced({name: laptop, price: laptopPrice})])
    ->whenCmd(ChangeSyncedPrice({productId: p1, price: laptopChangedPrice}))
    ->thenEvent(CatalogProductPriceChanged({productId: p1, price: laptopChangedPrice}))
  )

  // scenario-id: 76ba6d75-b136-413c-b225-d8f40b0fda6c
  test("re-syncing identical product data produces no events (idempotent)", () =>
    givenEvents([CatalogProductSynced({name: laptop, price: laptopPrice})])
    ->whenCmd(SyncNewProduct({productId: p1, name: laptop, price: laptopPrice}))
    ->thenNoEvent
  )

  // scenario-id: 0ed2ff32-af9f-47b4-88e7-1cea906dca7b
  test("re-applying the current price produces no events (idempotent)", () =>
    givenEvents([CatalogProductSynced({name: laptop, price: laptopPrice})])
    ->whenCmd(ChangeSyncedPrice({productId: p1, price: laptopPrice}))
    ->thenNoEvent
  )

  // scenario-id: beb2c75d-f258-49e9-bf75-949c00297f86
  test("WithdrawSyncedProduct produces CatalogProductWithdrawn", () =>
    givenEvents([CatalogProductSynced({name: laptop, price: laptopPrice})])
    ->whenCmd(WithdrawSyncedProduct({productId: p1}))
    ->thenEvent(CatalogProductWithdrawn({productId: p1}))
  )

  // scenario-id: 224a3bf7-0231-4ee4-ad3e-6ace53abdc13
  test("withdrawing an already-withdrawn product produces no events", () =>
    givenEvents([CatalogProductSynced({name: laptop, price: laptopPrice}), CatalogProductWithdrawn])
    ->whenCmd(WithdrawSyncedProduct({productId: p1}))
    ->thenNoEvent
  )

  // The assertion that pins the shadow as the source. Ordering restores the name
  // and price it kept through the withdrawal — Catalog's `ProductRelisted` carries
  // neither, and is never asked to.
  // scenario-id: c475bba4-415d-4461-bbaf-f511e4999b1e
  test("RelistSyncedProduct restores name and price from the shadow", () =>
    givenEvents([CatalogProductSynced({name: laptop, price: laptopPrice}), CatalogProductWithdrawn])
    ->whenCmd(RelistSyncedProduct({productId: p1}))
    ->thenEvent(CatalogProductRelisted({productId: p1, name: laptop, price: laptopPrice}))
  )

  // And the latest price, not the one it was first synced at: the shadow keeps
  // being maintained while the product is off the shelf.
  // scenario-id: e8087d7c-15a7-416b-9662-1f0fc1e12b36
  test("and restores the price it was last repriced to", () =>
    givenEvents([
      CatalogProductSynced({name: laptop, price: laptopPrice}),
      CatalogProductPriceChanged({price: laptopChangedPrice}),
      CatalogProductWithdrawn,
    ])
    ->whenCmd(RelistSyncedProduct({productId: p1}))
    ->thenEvent(CatalogProductRelisted({productId: p1, name: laptop, price: laptopChangedPrice}))
  )

  // scenario-id: 832afe90-b0e1-4f59-8ae5-d7ee17eb8f2a
  test("relisting a product that is not withdrawn produces no events", () =>
    givenEvents([CatalogProductSynced({name: laptop, price: laptopPrice})])
    ->whenCmd(RelistSyncedProduct({productId: p1}))
    ->thenNoEvent
  )

  // Nothing to restore, so nothing is invented: a row with a made-up name and a
  // zero price would appear in the shopper's catalog backed by no Catalog product.
  // scenario-id: e44fa5b2-b90c-43cc-bf7b-924ba3582c8a
  test("relisting a product never synced produces no events", () =>
    givenEvents([])->whenCmd(RelistSyncedProduct({productId: p1}))->thenNoEvent
  )
})
