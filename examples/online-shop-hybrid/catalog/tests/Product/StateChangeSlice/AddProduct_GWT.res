@@reventless.gwt

// Prices are money now, so a test writes the amount a person would say and
// converts it once. `ofMajor` scales by the currency's own exponent, which is
// what keeps the literal honest: 9.99 EUR is 999 cents, and the same call on a
// JPY price would scale by 1.
let eur = amount => Reventless.Money.ofMajor(~amount, ~currency=EUR)

describe("AddProduct StateChangeSlice", () => {
  test("adds product when the referenced category exists", () =>
    givenEvents([CategoryAdded({categoryId: "cat1"})])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1"}),
    )
    ->thenEvent(
      ProductAdded({
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: eur(999.99),
        imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg",
        categoryId: "cat1",
      }),
    )
  )

  test("rejects when the referenced category does not exist", () =>
    givenEvents([])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1"}),
    )
    ->thenError(CategoryNotFound)
  )

  test("rejects when the referenced category is archived", () =>
    givenEvents([CategoryAdded({categoryId: "cat1"}), CategoryArchived({categoryId: "cat1"})])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1"}),
    )
    ->thenError(CategoryNotFound)
  )

  test("existing product returns ProductAlreadyExists", () =>
    givenEvents([CategoryAdded({categoryId: "cat1"}), ProductAdded({productId: "p1"})])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), imageUrl: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", categoryId: "cat1"}),
    )
    ->thenError(ProductAlreadyExists)
  )

  // A sibling product in the same category is NOT in this product's decision read:
  // `categoryId` is an inferred cross-partition reference, so the category clause
  // reads only `CategoryAdded` / `CategoryArchived`, and the `productId` clause
  // returns only p2's own (absent) `ProductAdded`. So p2's history carries no
  // sibling `ProductAdded` — exactly what makes the plain existence check correct.
  test("a sibling product in the same category does not block a new product", () =>
    givenEvents([CategoryAdded({categoryId: "cat1"})])
    ->whenCmd(
      AddProduct({productId: "p2", name: "Mouse", description: "y", price: eur(19.99), imageUrl: "/uploads/b52d8f14-3c60-42ab-9e77-1d4a8c0f6e23/p2.jpg", categoryId: "cat1"}),
    )
    ->thenEvent(
      ProductAdded({
        productId: "p2",
        name: "Mouse",
        description: "y",
        price: eur(19.99),
        imageUrl: "/uploads/b52d8f14-3c60-42ab-9e77-1d4a8c0f6e23/p2.jpg",
        categoryId: "cat1",
      }),
    )
  )
})
