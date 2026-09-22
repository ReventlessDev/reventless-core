@@reventless.gwt(Products_Projections.ProductMapping)

let added = Product.Added({
  name: "Laptop",
  description: "A laptop",
  price: 999.99,
  imageUrl: "/productImages/laptop.jpg",
})

describe("Products ReadModel ← Product", () => {
  // scenario-id: 81836c9a-93ca-4326-ad59-deceb23d8ab0
  test("Added sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(added)
    ->thenState({
      Products.name: "Laptop",
      description: "A laptop",
      price: 999.99,
      imageUrl: "/productImages/laptop.jpg",
    })
  )

  // scenario-id: aaf1e1d4-f6b6-4d1d-904f-1cbb2e0af1dc
  test("NameUpdated updates the name", () =>
    givenEvents([added])
    ->whenEvent(Product.NameUpdated({name: "Gaming Laptop"}))
    ->thenState({
      Products.name: "Gaming Laptop",
      description: "A laptop",
      price: 999.99,
      imageUrl: "/productImages/laptop.jpg",
    })
  )

  // scenario-id: 30def838-8ffc-449c-be89-3632e993b1c7
  test("DescriptionUpdated updates the description", () =>
    givenEvents([added])
    ->whenEvent(Product.DescriptionUpdated({description: "A high-end laptop"}))
    ->thenState({
      Products.name: "Laptop",
      description: "A high-end laptop",
      price: 999.99,
      imageUrl: "/productImages/laptop.jpg",
    })
  )

  // scenario-id: 087f6d0c-7258-4d90-a78e-90e0f2832f95
  test("PriceUpdated updates the price", () =>
    givenEvents([added])
    ->whenEvent(Product.PriceUpdated({price: 899.99}))
    ->thenState({
      Products.name: "Laptop",
      description: "A laptop",
      price: 899.99,
      imageUrl: "/productImages/laptop.jpg",
    })
  )

  // scenario-id: dbebb7b6-7db1-4405-8d4d-d5b5a6cc87df
  test("ImageUpdated updates the stored ref", () =>
    givenEvents([added])
    ->whenEvent(Product.ImageUpdated({imageUrl: "/productImages/laptop-v2.jpg"}))
    ->thenState({
      Products.name: "Laptop",
      description: "A laptop",
      price: 999.99,
      imageUrl: "/productImages/laptop-v2.jpg",
    })
  )
})
