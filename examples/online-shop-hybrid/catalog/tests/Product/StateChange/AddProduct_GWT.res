@@reventless.gwt

open CatalogExamples

// Prices are money, so a test writes the amount a person would say and converts
// it once. `ofMajor` scales by the currency's own exponent, which is what keeps
// the literal honest: 9.99 EUR is 999 cents, and the same call on a JPY price
// would scale by 1.

describe("AddProduct StateChangeSlice", () => {
  // scenario-id: b0e222ce-b661-4537-931d-bd4e3b540109
  test("adds product when the referenced category exists", () =>
    givenEvents([CategoryAdded({categoryId: cat1})])
    ->whenCmd(
      AddProduct({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
    )
    ->thenEvent(
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
    )
  )

  // scenario-id: 007bc729-0859-4ec2-a5f3-ab28550d4200
  test("rejects when the referenced category does not exist", () =>
    givenEvents([])
    ->whenCmd(
      AddProduct({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
    )
    ->thenError(CategoryNotFound)
  )

  // scenario-id: 21f83631-b681-4202-a87b-5645e060dad5
  test("rejects when the referenced category is archived", () =>
    givenEvents([CategoryAdded({categoryId: cat1}), CategoryArchived({categoryId: cat1})])
    ->whenCmd(
      AddProduct({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
    )
    ->thenError(CategoryNotFound)
  )

  // scenario-id: b1673c80-7868-46e7-b2a2-81f05df79a29
  test("existing product returns ProductAlreadyExists", () =>
    givenEvents([CategoryAdded({categoryId: cat1}), ProductAdded({productId: p1})])
    ->whenCmd(
      AddProduct({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
    )
    ->thenError(ProductAlreadyExists)
  )

  // A sibling product in the same category is NOT in this product's decision read:
  // `categoryId` is an inferred cross-partition reference, so the category clause
  // reads only `CategoryAdded` / `CategoryArchived`, and the `productId` clause
  // returns only p2's own (absent) `ProductAdded`. So p2's history carries no
  // sibling `ProductAdded` — exactly what makes the plain existence check correct.
  // scenario-id: b8e3a265-efe3-479d-8c4f-2b5cb0a1141a
  test("a sibling product in the same category does not block a new product", () =>
    givenEvents([CategoryAdded({categoryId: cat1})])
    ->whenCmd(
      AddProduct({
        productId: p2,
        name: "Mouse",
        description: "y",
        price: buchPrice,
        categoryId: cat1,
      }),
    )
    ->thenEvent(
      ProductAdded({
        productId: p2,
        name: "Mouse",
        description: "y",
        price: buchPrice,
        categoryId: cat1,
      }),
    )
  )
})
