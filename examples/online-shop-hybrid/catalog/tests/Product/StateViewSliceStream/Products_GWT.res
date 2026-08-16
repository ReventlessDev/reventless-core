@@reventless.gwt

// Prices are money now, so a test writes the amount a person would say and
// converts it once. `ofMajor` scales by the currency's own exponent, which is
// what keeps the literal honest: 9.99 EUR is 999 cents, and the same call on a
// JPY price would scale by 1.
let eur = amount => Reventless.Money.ofMajor(~amount, ~currency=EUR)

describe("Products StateViewSliceStream", () => {
  test("ProductAdded creates a row", () =>
    givenEvents([])
    ->whenEvent(
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1"}),
    )
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "x", price: eur(999.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1", shelfStatus: Listed},
    )
  )

  test("ProductNameChanged updates the name", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1"}),
    ])
    ->whenEvent(ProductNameChanged({productId: "p1", name: "Gaming Laptop"}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Gaming Laptop", description: "x", price: eur(999.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1", shelfStatus: Listed},
    )
  )

  test("ProductDescriptionChanged updates the description", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1"}),
    ])
    ->whenEvent(ProductDescriptionChanged({productId: "p1", description: "high-end"}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "high-end", price: eur(999.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1", shelfStatus: Listed},
    )
  )

  test("ProductPriceChanged updates the price", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1"}),
    ])
    ->whenEvent(ProductPriceChanged({productId: "p1", price: eur(899.99)}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "x", price: eur(899.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1", shelfStatus: Listed},
    )
  )

  test("ProductImageChanged updates the image", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1"}),
    ])
    ->whenEvent(ProductImageChanged({productId: "p1", imageUrl: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-new.jpg"}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "x", price: eur(999.99), imageUrl: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-new.jpg", categoryId: "cat1", shelfStatus: Listed},
    )
  )
})
