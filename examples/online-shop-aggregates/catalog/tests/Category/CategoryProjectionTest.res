// Unit tests for Category projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

include ReventlessGwt.MultiSourceProjection_GWT.Make(Categories_Projections.CategoryMapping)

describe("CategoryProjection:", () => {
  test("Added sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(Category.Added({name: "Electronics"}))
    ->thenState({Categories.name: "Electronics", archived: false})
  )

  test("Renamed after creation updates name", () =>
    givenEvents([Category.Added({name: "Electronics"})])
    ->whenEvent(Category.Renamed({name: "Consumer Electronics"}))
    ->thenState({
      Categories.name: "Consumer Electronics",
      archived: false,
    })
  )

  test("Archived after creation sets archived flag", () =>
    givenEvents([Category.Added({name: "Electronics"})])
    ->whenEvent(Category.Archived)
    ->thenState({Categories.name: "Electronics", archived: true})
  )
})
