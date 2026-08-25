@@reventless.gwt

// Prices are money, so a test writes the amount a person would say and pairs it
// with a currency. `make` rounds to the decimals EUR has and scales nothing:
// 9.99 EUR is 9.99, and the same call on a JPY price would round to a whole yen.
let eur = amount => Reventless.Money.make(~amount, ~currency=EUR)

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

  // The row leaves the view rather than being marked. This answers "what can I
  // order", and an operator reading it is elevated — a `@retired` flag here would
  // hide a withdrawn product from the shopper correctly and show it to the
  // operator, in the one catalog that is supposed to be the shopper's.
  test("CatalogProductWithdrawn removes the row", () =>
    givenEvents([CatalogProductSynced({productId: "p1", name: "Laptop", price: eur(999.99)})])
    ->whenEvent(CatalogProductWithdrawn({productId: "p1"}))
    ->thenNoState
  )

  test("CatalogProductRelisted puts it back with its name and price", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1", name: "Laptop", price: eur(999.99)}),
      CatalogProductWithdrawn({productId: "p1"}),
    ])
    ->whenEvent(CatalogProductRelisted({productId: "p1", name: "Laptop", price: eur(899.99)}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", price: eur(899.99)})
  )
})
