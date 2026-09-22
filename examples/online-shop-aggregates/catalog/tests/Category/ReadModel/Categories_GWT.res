@@reventless.gwt(Categories_Projections.CategoryMapping)

describe("Categories ReadModel ← Category", () => {
  // scenario-id: d3a10976-599d-4ced-b604-25f57a15d2db
  test("Added sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(Category.Added({name: "Electronics"}))
    ->thenState({Categories.name: "Electronics", archived: false})
  )

  // scenario-id: 700b948d-9773-4c84-90b4-8167c4240ce0
  test("Renamed updates the name", () =>
    givenEvents([Category.Added({name: "Electronics"})])
    ->whenEvent(Category.Renamed({name: "Consumer Electronics"}))
    ->thenState({Categories.name: "Consumer Electronics", archived: false})
  )

  // scenario-id: 5ad0dd16-f778-4df9-b4cb-8f5b86548dbd
  test("Archived sets archived flag", () =>
    givenEvents([Category.Added({name: "Electronics"})])
    ->whenEvent(Category.Archived)
    ->thenState({Categories.name: "Electronics", archived: true})
  )
})
