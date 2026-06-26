@@reventless.gwt

describe("Categories StateViewSliceStream", () => {
  test("CategoryAdded creates a row", () =>
    givenEvents([])
    ->whenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"}))
    ->thenStateWithId("c1", {categoryId: "c1", name: "Electronics", archived: false})
  )

  test("CategoryRenamed updates the name", () =>
    givenEvents([CategoryAdded({categoryId: "c1", name: "Electronics"})])
    ->whenEvent(CategoryRenamed({categoryId: "c1", name: "Consumer Electronics"}))
    ->thenStateWithId("c1", {categoryId: "c1", name: "Consumer Electronics", archived: false})
  )

  test("CategoryArchived sets archived flag", () =>
    givenEvents([CategoryAdded({categoryId: "c1", name: "Electronics"})])
    ->whenEvent(CategoryArchived({categoryId: "c1"}))
    ->thenStateWithId("c1", {categoryId: "c1", name: "Electronics", archived: true})
  )
})
