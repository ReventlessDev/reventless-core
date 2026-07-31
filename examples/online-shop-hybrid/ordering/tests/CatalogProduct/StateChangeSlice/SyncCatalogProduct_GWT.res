@@reventless.gwt

// Prices are money now, so a test writes the amount a person would say and
// converts it once. `ofMajor` scales by the currency's own exponent, which is
// what keeps the literal honest: 9.99 EUR is 999 cents, and the same call on a
// JPY price would scale by 1.
let eur = amount => Reventless.Money.ofMajor(~amount, ~currency=EUR)

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
})
