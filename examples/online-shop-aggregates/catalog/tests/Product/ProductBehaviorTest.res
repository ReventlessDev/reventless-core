// Unit tests for Product aggregate behavior.
// Uses the BehaviorTest DSL for pure synchronous testing.

open Product

include ReventlessGwt.Behavior_GWT.MakeFromAggregate(Product, ProductBehavior)

describe("ProductBehavior:", () => {
  describe("Add", () => {
    test(
      "on new aggregate produces Added",
      () =>
        givenEvents([])
        ->whenCmd(
          Add({
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        )
        ->thenEvent(
          Added({
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ),
    )

    test(
      "on existing aggregate returns ProductAlreadyExists error",
      () =>
        givenEvents([
          Added({
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ])
        ->whenCmd(
          Add({name: "Laptop 2", description: "Another", price: 1.0}),
        )
        ->thenError(ProductAlreadyExists),
    )
  })

  describe("UpdateName", () => {
    test(
      "on non-existent aggregate returns ProductNotFound error",
      () =>
        givenEvents([])
        ->whenCmd(UpdateName({name: "New Name"}))
        ->thenError(ProductNotFound),
    )

    test(
      "on existing product produces NameUpdated",
      () =>
        givenEvents([
          Added({
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ])
        ->whenCmd(UpdateName({name: "Gaming Laptop"}))
        ->thenEvent(NameUpdated({name: "Gaming Laptop"})),
    )
  })

  describe("UpdateDescription", () => {
    test(
      "on existing product produces DescriptionUpdated",
      () =>
        givenEvents([
          Added({
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ])
        ->whenCmd(UpdateDescription({description: "A high-end laptop"}))
        ->thenEvent(
          DescriptionUpdated({description: "A high-end laptop"}),
        ),
    )
  })

  describe("UpdatePrice", () => {
    test(
      "on existing product produces PriceUpdated",
      () =>
        givenEvents([
          Added({
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ])
        ->whenCmd(UpdatePrice({price: 899.99}))
        ->thenEvent(PriceUpdated({price: 899.99})),
    )
  })
})
