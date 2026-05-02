@@reventless.gwt(Products_Projections.ProductMapping)

describe("Products ReadModel ← Product", () => {
  test("Added sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(Product.Added({name: "Laptop", description: "A laptop", price: 999.99}))
    ->thenState({Products.name: "Laptop", description: "A laptop", price: 999.99})
  )

  test("NameUpdated updates the name", () =>
    givenEvents([Product.Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenEvent(Product.NameUpdated({name: "Gaming Laptop"}))
    ->thenState({Products.name: "Gaming Laptop", description: "A laptop", price: 999.99})
  )

  test("DescriptionUpdated updates the description", () =>
    givenEvents([Product.Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenEvent(Product.DescriptionUpdated({description: "A high-end laptop"}))
    ->thenState({Products.name: "Laptop", description: "A high-end laptop", price: 999.99})
  )

  test("PriceUpdated updates the price", () =>
    givenEvents([Product.Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenEvent(Product.PriceUpdated({price: 899.99}))
    ->thenState({Products.name: "Laptop", description: "A laptop", price: 899.99})
  )
})
