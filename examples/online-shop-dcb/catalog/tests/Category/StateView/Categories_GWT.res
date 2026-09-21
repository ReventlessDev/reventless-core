@@reventless.gwt

let catId = CategoryId.make

describe("Categories StateViewSlice", () => {
  test("CategoryAdded creates a row", () =>
    givenEvents([])
    ->whenEvent(CategoryAdded({categoryId: catId("c1"), name: "Electronics"}))
    ->thenStateWithId("c1", {categoryId: catId("c1"), name: "Electronics", archived: false})
  )

  test("CategoryRenamed updates the name", () =>
    givenEvents([CategoryAdded({categoryId: catId("c1"), name: "Electronics"})])
    ->whenEvent(CategoryRenamed({categoryId: catId("c1"), name: "Consumer Electronics"}))
    ->thenStateWithId(
      "c1",
      {categoryId: catId("c1"), name: "Consumer Electronics", archived: false},
    )
  )

  test("CategoryArchived sets archived flag", () =>
    givenEvents([CategoryAdded({categoryId: catId("c1"), name: "Electronics"})])
    ->whenEvent(CategoryArchived({categoryId: catId("c1")}))
    ->thenStateWithId("c1", {categoryId: catId("c1"), name: "Electronics", archived: true})
  )
})
