@@reventless.gwt

open OrderingExamples

// Prices are money, so a test writes the amount a person would say and converts
// it once. `ofMajor` scales by the currency's own exponent, which is what keeps
// the literal honest: 9.99 EUR is 999 cents, and the same call on a JPY price
// would scale by 1.

describe("AvailableProducts StateViewSliceStream", () => {
  // scenario-id: 3296c87a-2296-4561-aafc-078ea72e3613
  test("CatalogProductSynced creates a row", () =>
    givenEvents([])
    ->whenEvent(CatalogProductSynced({productId: p1, name: laptop, price: laptopPrice}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, price: laptopPrice})
  )

  // scenario-id: dfe57c51-86f7-4536-b5a2-1cbbb9954ac9
  test("CatalogProductPriceChanged updates the price", () =>
    givenEvents([CatalogProductSynced({productId: p1, name: laptop, price: laptopPrice})])
    ->whenEvent(CatalogProductPriceChanged({productId: p1, price: laptopChangedPrice}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, price: laptopChangedPrice})
  )

  // The row leaves the view rather than being marked. This answers "what can I
  // order", and an operator reading it is elevated — a `@retired` flag here would
  // hide a withdrawn product from the shopper correctly and show it to the
  // operator, in the one catalog that is supposed to be the shopper's.
  // scenario-id: c8a6785b-6fe5-4c03-a0e9-ddc5f32ba867
  test("CatalogProductWithdrawn removes the row", () =>
    givenEvents([CatalogProductSynced({productId: p1, name: laptop, price: laptopPrice})])
    ->whenEvent(CatalogProductWithdrawn({productId: p1}))
    ->thenNoState
  )

  // scenario-id: 8f1acb16-da53-4243-8a09-4af89b226919
  test("CatalogProductRelisted puts it back with its name and price", () =>
    givenEvents([
      CatalogProductSynced({productId: p1, name: laptop, price: laptopPrice}),
      CatalogProductWithdrawn({productId: p1}),
    ])
    ->whenEvent(CatalogProductRelisted({productId: p1, name: laptop, price: laptopChangedPrice}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, price: laptopChangedPrice})
  )
})
