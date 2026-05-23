@@reventless.gwt

describe("AvailableProducts StateViewSliceStream", () => {
  test("CatalogProductSynced creates a row", () =>
    givenEvents([])
    ->whenEvent(CatalogProductSynced({productId: "p1", name: "Laptop", price: 999.99}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", price: 999.99})
  )

  test("CatalogProductPriceChanged updates the price", () =>
    givenEvents([CatalogProductSynced({productId: "p1", name: "Laptop", price: 999.99})])
    ->whenEvent(CatalogProductPriceChanged({productId: "p1", price: 899.99}))
    ->thenStateWithId("p1", {productId: "p1", name: "Laptop", price: 899.99})
  )
})
