@@reventless.gwt

describe("Product Behavior", () => {
  test("Add on new aggregate produces Added", () =>
    givenEvents([])
    ->whenCmd(Add({name: "Laptop", description: "A laptop", price: 999.99}))
    ->thenEvent(Added({name: "Laptop", description: "A laptop", price: 999.99}))
  )

  test("Add on existing aggregate returns ProductAlreadyExists", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(Add({name: "Laptop 2", description: "Another", price: 1.0}))
    ->thenError(ProductAlreadyExists)
  )

  test("UpdateName on non-existent aggregate returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateName({name: "New Name"}))
    ->thenError(ProductNotFound)
  )

  test("UpdateName on existing product produces NameUpdated", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(UpdateName({name: "Gaming Laptop"}))
    ->thenEvent(NameUpdated({name: "Gaming Laptop"}))
  )

  test("UpdateName to same name produces no events (idempotent)", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(UpdateName({name: "Laptop"}))
    ->thenNoEvent
  )

  test("UpdateDescription on non-existent aggregate returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateDescription({description: "x"}))
    ->thenError(ProductNotFound)
  )

  test("UpdateDescription on existing product produces DescriptionUpdated", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(UpdateDescription({description: "A high-end laptop"}))
    ->thenEvent(DescriptionUpdated({description: "A high-end laptop"}))
  )

  test("UpdateDescription to same description produces no events (idempotent)", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(UpdateDescription({description: "A laptop"}))
    ->thenNoEvent
  )

  test("UpdatePrice on non-existent aggregate returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdatePrice({price: 1.0}))
    ->thenError(ProductNotFound)
  )

  test("UpdatePrice on existing product produces PriceUpdated", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(UpdatePrice({price: 899.99}))
    ->thenEvent(PriceUpdated({price: 899.99}))
  )

  test("UpdatePrice to same price produces no events (idempotent)", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(UpdatePrice({price: 999.99}))
    ->thenNoEvent
  )
})
