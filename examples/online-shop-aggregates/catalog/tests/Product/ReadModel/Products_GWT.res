@@reventless.gwt(Products_Projections.ProductMapping)

let added = Product.Added({
  name: "Laptop",
  description: "A laptop",
  price: 999.99,
  imageUrl: "/productImages/laptop.jpg",
})

describe("Products ReadModel ← Product", () => {
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
