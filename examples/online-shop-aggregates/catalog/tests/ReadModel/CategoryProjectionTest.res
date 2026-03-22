// Unit tests for Category projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

include ReventlessInMemory.ProjectionTest.Make(CategoriesProjections.CategoryMapping)

describe("CategoryProjection:", () => {
  test("Added sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(Category.Added({name: "Electronics"}))
    ->thenState({CategoriesReadModel.name: "Electronics", archived: false})
  )

  test("Renamed after creation updates name", () =>
    givenEvents([Category.Added({name: "Electronics"})])
    ->whenEvent(Category.Renamed({name: "Consumer Electronics"}))
    ->thenState({
      CategoriesReadModel.categoryId: "id",
      name: "Consumer Electronics",
      archived: false,
    })
  )

  test("Archived after creation sets archived flag", () =>
    givenEvents([Category.Added({name: "Electronics"})])
    ->whenEvent(Category.Archived)
    ->thenState({CategoriesReadModel.name: "Electronics", archived: true})
  )
})
