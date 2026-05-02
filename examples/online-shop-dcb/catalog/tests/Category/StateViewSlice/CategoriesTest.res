// Pure unit tests for Categories StateViewSlice projection.

open Reventless
open Jest
open Expect

let baseCategory: Categories.state = {categoryId: "c1", name: "Electronics", archived: false}

// Apply the first Update action's function to a base state for assertion.
let applyFirstUpdate = (actions, baseState) =>
  actions->Array.reduce(baseState, (s, action) =>
    switch action {
    | Projection.Update(_, fn) => fn(s)
    | _ => s
    })

describe("Categories_Projection.project:", () => {
  test("CategoryAdded creates new state", () =>
    expect(
      Categories_Projection.project(
        Categories.CategoryAdded({categoryId: "c1", name: "Electronics"}),
      ),
    )->toEqual([
      Projection.Set(
        "c1",
        {Categories.categoryId: "c1", name: "Electronics", archived: false},
      ),
    ])
  )

  test("CategoryRenamed Update function changes name", () =>
    expect(
      Categories_Projection.project(
        Categories.CategoryRenamed({categoryId: "c1", name: "Consumer Electronics"}),
      )->applyFirstUpdate(baseCategory),
    )->toEqual({...baseCategory, name: "Consumer Electronics"})
  )

  test("CategoryArchived Update function sets archived=true", () =>
    expect(
      Categories_Projection.project(
        Categories.CategoryArchived({categoryId: "c1"}),
      )->applyFirstUpdate(baseCategory),
    )->toEqual({...baseCategory, archived: true})
  )
})
