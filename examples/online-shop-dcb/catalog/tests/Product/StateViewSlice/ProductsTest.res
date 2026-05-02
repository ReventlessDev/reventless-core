// Pure unit tests for Products StateViewSlice projection.

open Reventless
open Jest
open Expect

let baseProduct: Products.state = {
  productId: "p1",
  name: "Laptop",
  description: "A laptop",
  price: 999.99,
}

// Apply the first Update action's function to a base state for assertion.
let applyFirstUpdate = (actions, baseState) =>
  actions->Array.reduce(baseState, (s, action) =>
    switch action {
    | Projection.Update(_, fn) => fn(s)
    | _ => s
    })

describe("Products_Projection.project:", () => {
  test("ProductAdded creates new state", () =>
    expect(
      Products_Projection.project(
        Products.ProductAdded({
          productId: "p1",
          name: "Laptop",
          description: "A laptop",
          price: 999.99,
        }),
      ),
    )->toEqual([
      Projection.Set(
        "p1",
        {Products.productId: "p1", name: "Laptop", description: "A laptop", price: 999.99},
      ),
    ])
  )

  test("ProductNameChanged Update function changes name", () =>
    expect(
      Products_Projection.project(
        Products.ProductNameChanged({productId: "p1", name: "Gaming Laptop"}),
      )->applyFirstUpdate(baseProduct),
    )->toEqual({...baseProduct, name: "Gaming Laptop"})
  )

  test("ProductDescriptionChanged Update function changes description", () =>
    expect(
      Products_Projection.project(
        Products.ProductDescriptionChanged({
          productId: "p1",
          description: "A high-end laptop",
        }),
      )->applyFirstUpdate(baseProduct),
    )->toEqual({...baseProduct, description: "A high-end laptop"})
  )

  test("ProductPriceChanged Update function changes price", () =>
    expect(
      Products_Projection.project(
        Products.ProductPriceChanged({productId: "p1", price: 899.99}),
      )->applyFirstUpdate(baseProduct),
    )->toEqual({...baseProduct, price: 899.99})
  )
})
