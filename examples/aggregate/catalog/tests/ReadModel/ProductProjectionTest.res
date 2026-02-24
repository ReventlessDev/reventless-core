// Unit tests for Product projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

open Product
open ProductsReadModel

include ReventlessInMemory.ProjectionTest.Make(ProductsProjections.ProductMapping)

describe("ProductProjection:", () => {
  test("ProductAdded sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(
      ProductAdded({
        productId: "prod-1",
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      }),
    )
    ->thenState({
      productId: "prod-1",
      name: "Laptop",
      description: "A laptop",
      price: 999.99,
    })
  )

  test("ProductNameUpdated after creation updates name", () =>
    givenEvents([
      ProductAdded({
        productId: "prod-1",
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      }),
    ])
    ->whenEvent(ProductNameUpdated({productId: "prod-1", name: "Gaming Laptop"}))
    ->thenState({
      productId: "prod-1",
      name: "Gaming Laptop",
      description: "A laptop",
      price: 999.99,
    })
  )

  test("ProductDescriptionUpdated after creation updates description", () =>
    givenEvents([
      ProductAdded({
        productId: "prod-1",
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      }),
    ])
    ->whenEvent(ProductDescriptionUpdated({productId: "prod-1", description: "A high-end laptop"}))
    ->thenState({
      productId: "prod-1",
      name: "Laptop",
      description: "A high-end laptop",
      price: 999.99,
    })
  )

  test("ProductPriceUpdated after creation updates price", () =>
    givenEvents([
      ProductAdded({
        productId: "prod-1",
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      }),
    ])
    ->whenEvent(ProductPriceUpdated({productId: "prod-1", price: 899.99}))
    ->thenState({
      productId: "prod-1",
      name: "Laptop",
      description: "A laptop",
      price: 899.99,
    })
  )
})
