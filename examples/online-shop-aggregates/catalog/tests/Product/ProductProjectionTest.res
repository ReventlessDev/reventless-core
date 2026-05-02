// Unit tests for Product projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

open Product
open Products

include ReventlessGwt.MultiSourceProjection_GWT.Make(Products_Projections.ProductMapping)

describe("ProductProjection:", () => {
  test("Added sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(
      Added({
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      }),
    )
    ->thenState({
      name: "Laptop",
      description: "A laptop",
      price: 999.99,
    })
  )

  test("NameUpdated after creation updates name", () =>
    givenEvents([
      Added({
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      }),
    ])
    ->whenEvent(NameUpdated({name: "Gaming Laptop"}))
    ->thenState({
      name: "Gaming Laptop",
      description: "A laptop",
      price: 999.99,
    })
  )

  test("DescriptionUpdated after creation updates description", () =>
    givenEvents([
      Added({
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      }),
    ])
    ->whenEvent(DescriptionUpdated({description: "A high-end laptop"}))
    ->thenState({
      name: "Laptop",
      description: "A high-end laptop",
      price: 999.99,
    })
  )

  test("PriceUpdated after creation updates price", () =>
    givenEvents([
      Added({
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      }),
    ])
    ->whenEvent(PriceUpdated({price: 899.99}))
    ->thenState({
      name: "Laptop",
      description: "A laptop",
      price: 899.99,
    })
  )
})
