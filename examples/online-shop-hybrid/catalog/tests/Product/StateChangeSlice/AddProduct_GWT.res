@@reventless.gwt

// Prices are money, so a test writes the amount a person would say and converts
// it once. `ofMajor` scales by the currency's own exponent, which is what keeps
// the literal honest: 9.99 EUR is 999 cents, and the same call on a JPY price
// would scale by 1.
let eur = amount => Reventless.Money.ofMajor(~amount, ~currency=EUR)

describe("AddProduct StateChangeSlice", () => {
  test("adds product when the referenced category exists", () =>
    givenEvents([CategoryAdded({categoryId: "cat1", name: "Peripherals"})])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
    )
    ->thenEvent(
      ProductAdded({
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: eur(999.99),
        categoryId: "cat1",
        categoryName: "Peripherals",
      }),
    )
  )

  test("rejects when the referenced category does not exist", () =>
    givenEvents([])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
    )
    ->thenError(CategoryNotFound)
  )

  test("rejects when the referenced category is archived", () =>
    givenEvents([CategoryAdded({categoryId: "cat1", name: "Peripherals"}), CategoryArchived({categoryId: "cat1"})])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
    )
    ->thenError(CategoryNotFound)
  )

  test("existing product returns ProductAlreadyExists", () =>
    givenEvents([CategoryAdded({categoryId: "cat1", name: "Peripherals"}), ProductAdded({productId: "p1"})])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
    )
    ->thenError(ProductAlreadyExists)
  )

  // A sibling product in the same category is NOT in this product's decision read:
  // `categoryId` is an inferred cross-partition reference, so the category clause
  // reads only `CategoryAdded` / `CategoryArchived`, and the `productId` clause
  // returns only p2's own (absent) `ProductAdded`. So p2's history carries no
  // sibling `ProductAdded` — exactly what makes the plain existence check correct.
  test("a sibling product in the same category does not block a new product", () =>
    givenEvents([CategoryAdded({categoryId: "cat1", name: "Peripherals"})])
    ->whenCmd(
      AddProduct({productId: "p2", name: "Mouse", description: "y", price: eur(19.99), categoryId: "cat1"}),
    )
    ->thenEvent(
      ProductAdded({
        productId: "p2",
        name: "Mouse",
        description: "y",
        price: eur(19.99),
        categoryId: "cat1",
        categoryName: "Peripherals",
      }),
    )
  )

  // The category's name is captured as the shelf reads it *at the moment the
  // product is added*: a rename before this point is what the product records,
  // and one after it is not. A projection keyed by `productId` could not rewrite
  // every row of a renamed category, so freezing is the honest answer rather
  // than a compromise.
  test("a category renamed before the product is added is captured under the new name", () =>
    givenEvents([
      CategoryAdded({categoryId: "cat1", name: "Peripherals"}),
      CategoryRenamed({categoryId: "cat1", name: "Desk accessories"}),
    ])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
    )
    ->thenEvent(
      ProductAdded({
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: eur(999.99),
        categoryId: "cat1",
        categoryName: "Desk accessories",
      }),
    )
  )
})
