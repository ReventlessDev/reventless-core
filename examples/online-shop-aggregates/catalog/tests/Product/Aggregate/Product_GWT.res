@@reventless.gwt

let added = Added({
  name: "Laptop",
  description: "A laptop",
  price: 999.99,
  imageUrl: "/productImages/laptop.jpg",
})

describe("Product Behavior", () => {
  test("Add on new aggregate produces Added", () =>
    givenEvents([])
    ->whenCmd(
      Add({
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
        imageUrl: "/productImages/laptop.jpg",
      }),
    )
    ->thenEvent(added)
  )

  test("Add on existing aggregate returns ProductAlreadyExists", () =>
    givenEvents([added])
    ->whenCmd(
      Add({
        name: "Laptop 2",
        description: "Another",
        price: 1.0,
        imageUrl: "/productImages/laptop-2.jpg",
      }),
    )
    ->thenError(ProductAlreadyExists)
  )

  test("UpdateName on non-existent aggregate returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateName({name: "New Name"}))
    ->thenError(ProductNotFound)
  )

  test("UpdateName on existing product produces NameUpdated", () =>
    givenEvents([added])
    ->whenCmd(UpdateName({name: "Gaming Laptop"}))
    ->thenEvent(NameUpdated({name: "Gaming Laptop"}))
  )

  test("UpdateName to same name produces no events (idempotent)", () =>
    givenEvents([added])->whenCmd(UpdateName({name: "Laptop"}))->thenNoEvent
  )

  test("UpdateDescription on non-existent aggregate returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateDescription({description: "x"}))
    ->thenError(ProductNotFound)
  )

  test("UpdateDescription on existing product produces DescriptionUpdated", () =>
    givenEvents([added])
    ->whenCmd(UpdateDescription({description: "A high-end laptop"}))
    ->thenEvent(DescriptionUpdated({description: "A high-end laptop"}))
  )

  test("UpdateDescription to same description produces no events (idempotent)", () =>
    givenEvents([added])->whenCmd(UpdateDescription({description: "A laptop"}))->thenNoEvent
  )

  test("UpdatePrice on non-existent aggregate returns ProductNotFound", () =>
    givenEvents([])->whenCmd(UpdatePrice({price: 1.0}))->thenError(ProductNotFound)
  )

  test("UpdatePrice on existing product produces PriceUpdated", () =>
    givenEvents([added])
    ->whenCmd(UpdatePrice({price: 899.99}))
    ->thenEvent(PriceUpdated({price: 899.99}))
  )

  test("UpdatePrice to same price produces no events (idempotent)", () =>
    givenEvents([added])->whenCmd(UpdatePrice({price: 999.99}))->thenNoEvent
  )

  test("UpdateImage on non-existent aggregate returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateImage({imageUrl: "/productImages/laptop.jpg"}))
    ->thenError(ProductNotFound)
  )

  test("UpdateImage on existing product produces ImageUpdated", () =>
    givenEvents([added])
    ->whenCmd(UpdateImage({imageUrl: "/productImages/laptop-v2.jpg"}))
    ->thenEvent(ImageUpdated({imageUrl: "/productImages/laptop-v2.jpg"}))
  )

  test("UpdateImage to the same ref produces no events (idempotent)", () =>
    givenEvents([added])
    ->whenCmd(UpdateImage({imageUrl: "/productImages/laptop.jpg"}))
    ->thenNoEvent
  )
})
