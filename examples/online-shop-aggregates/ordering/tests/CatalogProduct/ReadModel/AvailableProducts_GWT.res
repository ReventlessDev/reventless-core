@@reventless.gwt(AvailableProducts_Projections.CatalogProductMapping)

describe("AvailableProducts ReadModel ← CatalogProduct", () => {
  // scenario-id: 845f7b2c-e29b-469f-a497-654927750d09
  test("Synced sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(CatalogProduct.Synced({name: "Laptop", price: 999.99}))
    ->thenState({AvailableProducts.name: "Laptop", price: 999.99})
  )

  // scenario-id: 272d70a8-20d7-4f33-bca1-ec101bd5f702
  test("PriceUpdated updates the price", () =>
    givenEvents([CatalogProduct.Synced({name: "Laptop", price: 999.99})])
    ->whenEvent(CatalogProduct.PriceUpdated({price: 899.99}))
    ->thenState({AvailableProducts.name: "Laptop", price: 899.99})
  )
})
