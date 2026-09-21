@@reventless.gwt

let pid = CatalogSpec.ProductId.make

describe("AvailableProducts StateViewSlice", () => {
  test("CatalogProductSynced creates a row", () =>
    givenEvents([])
    ->whenEvent(CatalogProductSynced({productId: pid("p1"), name: "Laptop", price: 999.99}))
    ->thenStateWithId("p1", {productId: pid("p1"), name: "Laptop", price: 999.99})
  )

  test("CatalogProductPriceChanged updates the price", () =>
    givenEvents([CatalogProductSynced({productId: pid("p1"), name: "Laptop", price: 999.99})])
    ->whenEvent(CatalogProductPriceChanged({productId: pid("p1"), price: 899.99}))
    ->thenStateWithId("p1", {productId: pid("p1"), name: "Laptop", price: 899.99})
  )
})
