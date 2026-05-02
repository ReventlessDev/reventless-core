@@reventless.gwt(Categories_Projections.CategoryMapping)

describe("Categories ReadModel ← Category", () => {
  test("Added sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(Category.Added({name: "Electronics"}))
    ->thenState({Categories.name: "Electronics", archived: false})
  )

  test("Renamed updates the name", () =>
    givenEvents([Category.Added({name: "Electronics"})])
    ->whenEvent(Category.Renamed({name: "Consumer Electronics"}))
    ->thenState({Categories.name: "Consumer Electronics", archived: false})
  )

  test("Archived sets archived flag", () =>
    givenEvents([Category.Added({name: "Electronics"})])
    ->whenEvent(Category.Archived)
    ->thenState({Categories.name: "Electronics", archived: true})
  )
})
