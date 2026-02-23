// Pure unit tests for ProductsView StateViewSlice projection.

open Jest
open Expect

let baseProduct: ProductsView.state = {
  productId: "p1",
  name: "Laptop",
  description: "A laptop",
  price: 999.99,
}

// Apply the first Update action's function to a base state for assertion.
let applyFirstUpdate = (actions, baseState) =>
  actions->Array.reduce(baseState, (s, action) =>
    switch action {
    | ReventlessSpec.Projection.Update(_, fn) => fn(s)
    | _ => s
    })

describe("ProductsView.project:", () => {
  test("ProductAdded creates new state", () =>
    expect(
      ProductsView.project(
        None,
        CatalogEventLog.ProductAdded({
          productId: "p1",
          name: "Laptop",
          description: "A laptop",
          price: 999.99,
        }),
      ),
    )->toEqual([
      ReventlessSpec.Projection.Set(
        "p1",
        {ProductsView.productId: "p1", name: "Laptop", description: "A laptop", price: 999.99},
      ),
    ])
  )

  test("ProductNameUpdated Update function changes name", () =>
    expect(
      ProductsView.project(
        None,
        CatalogEventLog.ProductNameUpdated({productId: "p1", name: "Gaming Laptop"}),
      )->applyFirstUpdate(baseProduct),
    )->toEqual({...baseProduct, name: "Gaming Laptop"})
  )

  test("ProductDescriptionUpdated Update function changes description", () =>
    expect(
      ProductsView.project(
        None,
        CatalogEventLog.ProductDescriptionUpdated({
          productId: "p1",
          description: "A high-end laptop",
        }),
      )->applyFirstUpdate(baseProduct),
    )->toEqual({...baseProduct, description: "A high-end laptop"})
  )

  test("ProductPriceUpdated Update function changes price", () =>
    expect(
      ProductsView.project(
        None,
        CatalogEventLog.ProductPriceUpdated({productId: "p1", price: 899.99}),
      )->applyFirstUpdate(baseProduct),
    )->toEqual({...baseProduct, price: 899.99})
  )

  test("Category events return empty (not handled by ProductsView)", () =>
    expect(
      ProductsView.project(None, CatalogEventLog.CategoryAdded({categoryId: "c1", name: "Books"})),
    )->toEqual([])
  )
})
