@@reventless.gwt

// Prices are money, so a test writes the amount a person would say and pairs it
// with a currency. `make` rounds to the decimals EUR has and scales nothing:
// 9.99 EUR is 9.99, and the same call on a JPY price would round to a whole yen.
let eur = amount => Reventless.Money.make(~amount, ~currency=EUR)

describe("SyncCatalogProduct StateChangeSlice", () => {
  test("SyncNewProduct produces CatalogProductSynced", () =>
    givenEvents([])
    ->whenCmd(SyncNewProduct({productId: "p1", name: "Laptop", price: eur(999.99)}))
    ->thenEvent(CatalogProductSynced({productId: "p1", name: "Laptop", price: eur(999.99)}))
  )

  test("ChangeSyncedPrice produces CatalogProductPriceChanged", () =>
    givenEvents([CatalogProductSynced({name: "Laptop", price: eur(999.99)})])
    ->whenCmd(ChangeSyncedPrice({productId: "p1", price: eur(899.99)}))
    ->thenEvent(CatalogProductPriceChanged({productId: "p1", price: eur(899.99)}))
  )

  test("re-syncing identical product data produces no events (idempotent)", () =>
    givenEvents([CatalogProductSynced({name: "Laptop", price: eur(999.99)})])
    ->whenCmd(SyncNewProduct({productId: "p1", name: "Laptop", price: eur(999.99)}))
    ->thenNoEvent
  )

  test("re-applying the current price produces no events (idempotent)", () =>
    givenEvents([CatalogProductSynced({name: "Laptop", price: eur(999.99)})])
    ->whenCmd(ChangeSyncedPrice({productId: "p1", price: eur(999.99)}))
    ->thenNoEvent
  )

  test("WithdrawSyncedProduct produces CatalogProductWithdrawn", () =>
    givenEvents([CatalogProductSynced({name: "Laptop", price: eur(999.99)})])
    ->whenCmd(WithdrawSyncedProduct({productId: "p1"}))
    ->thenEvent(CatalogProductWithdrawn({productId: "p1"}))
  )

  test("withdrawing an already-withdrawn product produces no events", () =>
    givenEvents([CatalogProductSynced({name: "Laptop", price: eur(999.99)}), CatalogProductWithdrawn])
    ->whenCmd(WithdrawSyncedProduct({productId: "p1"}))
    ->thenNoEvent
  )

  // The assertion that pins the shadow as the source. Ordering restores the name
  // and price it kept through the withdrawal — Catalog's `ProductRelisted` carries
  // neither, and is never asked to.
  test("RelistSyncedProduct restores name and price from the shadow", () =>
    givenEvents([CatalogProductSynced({name: "Laptop", price: eur(999.99)}), CatalogProductWithdrawn])
    ->whenCmd(RelistSyncedProduct({productId: "p1"}))
    ->thenEvent(CatalogProductRelisted({productId: "p1", name: "Laptop", price: eur(999.99)}))
  )

  // And the latest price, not the one it was first synced at: the shadow keeps
  // being maintained while the product is off the shelf.
  test("and restores the price it was last repriced to", () =>
    givenEvents([
      CatalogProductSynced({name: "Laptop", price: eur(999.99)}),
      CatalogProductPriceChanged({price: eur(899.99)}),
      CatalogProductWithdrawn,
    ])
    ->whenCmd(RelistSyncedProduct({productId: "p1"}))
    ->thenEvent(CatalogProductRelisted({productId: "p1", name: "Laptop", price: eur(899.99)}))
  )

  test("relisting a product that is not withdrawn produces no events", () =>
    givenEvents([CatalogProductSynced({name: "Laptop", price: eur(999.99)})])
    ->whenCmd(RelistSyncedProduct({productId: "p1"}))
    ->thenNoEvent
  )

  // Nothing to restore, so nothing is invented: a row with a made-up name and a
  // zero price would appear in the shopper's catalog backed by no Catalog product.
  test("relisting a product never synced produces no events", () =>
    givenEvents([])->whenCmd(RelistSyncedProduct({productId: "p1"}))->thenNoEvent
  )
})
