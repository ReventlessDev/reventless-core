@@reventless.gwt

describe("AddProduct StateChangeSlice", () => {
  test("adds product when the referenced category exists", () =>
    givenEvents([CategoryAdded({categoryId: "cat1"})])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: 999.99, categoryId: "cat1"}),
    )
    ->thenEvent(
      ProductAdded({
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: 999.99,
        categoryId: "cat1",
      }),
    )
  )

  test("rejects when the referenced category does not exist", () =>
    givenEvents([])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: 999.99, categoryId: "cat1"}),
    )
    ->thenError(CategoryNotFound)
  )

  test("rejects when the referenced category is archived", () =>
    givenEvents([CategoryAdded({categoryId: "cat1"}), CategoryArchived({categoryId: "cat1"})])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: 999.99, categoryId: "cat1"}),
    )
    ->thenError(CategoryNotFound)
  )

  test("existing product returns ProductAlreadyExists", () =>
    givenEvents([CategoryAdded({categoryId: "cat1"}), ProductAdded({productId: "p1"})])
    ->whenCmd(
      AddProduct({productId: "p1", name: "Laptop", description: "x", price: 999.99, categoryId: "cat1"}),
    )
    ->thenError(ProductAlreadyExists)
  )

  test("a sibling product in the same category does not block a new product", () =>
    givenEvents([CategoryAdded({categoryId: "cat1"}), ProductAdded({productId: "p1"})])
    ->whenCmd(
      AddProduct({productId: "p2", name: "Mouse", description: "y", price: 19.99, categoryId: "cat1"}),
    )
    ->thenEvent(
      ProductAdded({
        productId: "p2",
        name: "Mouse",
        description: "y",
        price: 19.99,
        categoryId: "cat1",
      }),
    )
  )
})
