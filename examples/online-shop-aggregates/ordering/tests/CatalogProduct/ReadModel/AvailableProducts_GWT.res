@@reventless.gwt(AvailableProducts_Projections.CatalogProductMapping)

describe("AvailableProducts ReadModel ← CatalogProduct", () => {
  test("Synced sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(CatalogProduct.Synced({name: "Laptop", price: 999.99}))
    ->thenState({AvailableProducts.name: "Laptop", price: 999.99})
  )

  test("PriceUpdated updates the price", () =>
    givenEvents([CatalogProduct.Synced({name: "Laptop", price: 999.99})])
    ->whenEvent(CatalogProduct.PriceUpdated({price: 899.99}))
    ->thenState({AvailableProducts.name: "Laptop", price: 899.99})
  )
})
