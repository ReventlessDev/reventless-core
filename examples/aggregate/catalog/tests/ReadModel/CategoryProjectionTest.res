// Unit tests for Category projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

include ReventlessInMemory.ProjectionTest.Make(CategoriesProjections.CategoryMapping)

describe("CategoryProjection:", () => {
  test("CategoryAdded sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(Category.CategoryAdded({categoryId: "cat-1", name: "Electronics"}))
    ->thenState({CategoriesReadModel.categoryId: "cat-1", name: "Electronics", archived: false})
  )

  test("CategoryRenamed after creation updates name", () =>
    givenEvents([Category.CategoryAdded({categoryId: "cat-1", name: "Electronics"})])
    ->whenEvent(Category.CategoryRenamed({categoryId: "cat-1", name: "Consumer Electronics"}))
    ->thenState({
      CategoriesReadModel.categoryId: "cat-1",
      name: "Consumer Electronics",
      archived: false,
    })
  )

  test("CategoryArchived after creation sets archived flag", () =>
    givenEvents([Category.CategoryAdded({categoryId: "cat-1", name: "Electronics"})])
    ->whenEvent(Category.CategoryArchived({categoryId: "cat-1"}))
    ->thenState({CategoriesReadModel.categoryId: "cat-1", name: "Electronics", archived: true})
  )
})
