@@reventless.gwt

// Prices are money now, so a test writes the amount a person would say and
// converts it once. `ofMajor` scales by the currency's own exponent, which is
// what keeps the literal honest: 9.99 EUR is 999 cents, and the same call on a
// JPY price would scale by 1.
let eur = amount => Reventless.Money.ofMajor(~amount, ~currency=EUR)

describe("AvailableProducts StateViewSliceStream", () => {
  test("CatalogProductSynced creates a row", () =>
    givenEvents([])
    ->whenEvent(CatalogProductSynced({productId: "p1", name: "Laptop", price: eur(999.99)}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", price: eur(999.99)})
  )

  test("CatalogProductPriceChanged updates the price", () =>
    givenEvents([CatalogProductSynced({productId: "p1", name: "Laptop", price: eur(999.99)})])
    ->whenEvent(CatalogProductPriceChanged({productId: "p1", price: eur(899.99)}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", price: eur(899.99)})
  )
})
