@@reventless.gwt

open Ordering_Examples

describe("AvailableProducts StateViewSlice", () => {
  // scenario-id: bbaa93a0-6f73-437b-948e-583c3f5b1b63
  test("CatalogProductSynced creates a row", () =>
    givenEvents([])
    ->whenEvent(CatalogProductSynced({productId: p1, name: laptop, price: 999.99}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, price: 999.99})
  )

  // scenario-id: def1787d-69b4-4e67-8d9b-c1d3adce0a4d
  test("CatalogProductPriceChanged updates the price", () =>
    givenEvents([CatalogProductSynced({productId: p1, name: laptop, price: 999.99})])
    ->whenEvent(CatalogProductPriceChanged({productId: p1, price: 899.99}))
    ->thenStateWithId("p1", {productId: p1, name: laptop, price: 899.99})
  )
})
