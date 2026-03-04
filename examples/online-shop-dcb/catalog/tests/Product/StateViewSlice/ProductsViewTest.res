// Pure unit tests for ProductsView StateViewSlice projection.

open Reventless
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
    | Projection.Update(_, fn) => fn(s)
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
      Projection.Set(
        "p1",
        {ProductsView.productId: "p1", name: "Laptop", description: "A laptop", price: 999.99},
      ),
    ])
  )

  test("ProductNameChanged Update function changes name", () =>
    expect(
      ProductsView.project(
        None,
        CatalogEventLog.ProductNameChanged({productId: "p1", name: "Gaming Laptop"}),
      )->applyFirstUpdate(baseProduct),
    )->toEqual({...baseProduct, name: "Gaming Laptop"})
  )

  test("ProductDescriptionChanged Update function changes description", () =>
    expect(
      ProductsView.project(
        None,
        CatalogEventLog.ProductDescriptionChanged({
          productId: "p1",
          description: "A high-end laptop",
        }),
      )->applyFirstUpdate(baseProduct),
    )->toEqual({...baseProduct, description: "A high-end laptop"})
  )

  test("ProductPriceChanged Update function changes price", () =>
    expect(
      ProductsView.project(
        None,
        CatalogEventLog.ProductPriceChanged({productId: "p1", price: 899.99}),
      )->applyFirstUpdate(baseProduct),
    )->toEqual({...baseProduct, price: 899.99})
  )

  test("Category events return empty (not handled by ProductsView)", () =>
    expect(
      ProductsView.project(None, CatalogEventLog.CategoryAdded({categoryId: "c1", name: "Books"})),
    )->toEqual([])
  )
})
