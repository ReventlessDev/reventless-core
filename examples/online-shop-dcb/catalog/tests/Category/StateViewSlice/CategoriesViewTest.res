// Pure unit tests for CategoriesView StateViewSlice projection.

open Reventless
open Jest
open Expect

let baseCategory: CategoriesView.state = {categoryId: "c1", name: "Electronics", archived: false}

// Apply the first Update action's function to a base state for assertion.
let applyFirstUpdate = (actions, baseState) =>
  actions->Array.reduce(baseState, (s, action) =>
    switch action {
    | Projection.Update(_, fn) => fn(s)
    | _ => s
    })

describe("CategoriesView.project:", () => {
  test("CategoryAdded creates new state", () =>
    expect(
      CategoriesView.project(
        CategoriesView.CategoryAdded({categoryId: "c1", name: "Electronics"}),
      ),
    )->toEqual([
      Projection.Set(
        "c1",
        {CategoriesView.categoryId: "c1", name: "Electronics", archived: false},
      ),
    ])
  )

  test("CategoryRenamed Update function changes name", () =>
    expect(
      CategoriesView.project(
        CategoriesView.CategoryRenamed({categoryId: "c1", name: "Consumer Electronics"}),
      )->applyFirstUpdate(baseCategory),
    )->toEqual({...baseCategory, name: "Consumer Electronics"})
  )

  test("CategoryArchived Update function sets archived=true", () =>
    expect(
      CategoriesView.project(
        CategoriesView.CategoryArchived({categoryId: "c1"}),
      )->applyFirstUpdate(baseCategory),
    )->toEqual({...baseCategory, archived: true})
  )
})
