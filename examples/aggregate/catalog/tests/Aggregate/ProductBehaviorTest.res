// Unit tests for Product aggregate behavior.
// Uses the BehaviorTest DSL for pure synchronous testing.

open Product

include ReventlessInMemory.BehaviorTest.Make(Product, ProductBehavior)

describe("ProductBehavior:", () => {
  describe("AddProduct", () => {
    test(
      "on new aggregate produces ProductAdded",
      () =>
        givenEvents([])
        ->whenCmd(
          AddProduct({
            productId: "prod-1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        )
        ->thenEvent(
          ProductAdded({
            productId: "prod-1",
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
          ProductAdded({
            productId: "prod-1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ])
        ->whenCmd(
          AddProduct({productId: "prod-1", name: "Laptop 2", description: "Another", price: 1.0}),
        )
        ->thenError(ProductAlreadyExists),
    )
  })

  describe("UpdateProductName", () => {
    test(
      "on non-existent aggregate returns ProductNotFound error",
      () =>
        givenEvents([])
        ->whenCmd(UpdateProductName({productId: "prod-1", name: "New Name"}))
        ->thenError(ProductNotFound),
    )

    test(
      "on existing product produces ProductNameUpdated",
      () =>
        givenEvents([
          ProductAdded({
            productId: "prod-1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ])
        ->whenCmd(UpdateProductName({productId: "prod-1", name: "Gaming Laptop"}))
        ->thenEvent(ProductNameUpdated({productId: "prod-1", name: "Gaming Laptop"})),
    )
  })

  describe("UpdateProductDescription", () => {
    test(
      "on existing product produces ProductDescriptionUpdated",
      () =>
        givenEvents([
          ProductAdded({
            productId: "prod-1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ])
        ->whenCmd(UpdateProductDescription({productId: "prod-1", description: "A high-end laptop"}))
        ->thenEvent(
          ProductDescriptionUpdated({productId: "prod-1", description: "A high-end laptop"}),
        ),
    )
  })

  describe("UpdateProductPrice", () => {
    test(
      "on existing product produces ProductPriceUpdated",
      () =>
        givenEvents([
          ProductAdded({
            productId: "prod-1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ])
        ->whenCmd(UpdateProductPrice({productId: "prod-1", price: 899.99}))
        ->thenEvent(ProductPriceUpdated({productId: "prod-1", price: 899.99})),
    )
  })
})
