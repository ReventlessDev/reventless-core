@@reventless.gwt

describe("Categories StateViewSliceStream", () => {
  test("CategoryAdded creates a row", () =>
    givenEvents([])
    ->whenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"}))
    ->thenStateWithId("c1", {categoryId: "c1", name: "Electronics", archived: false})
  )

  test("CategoryAdded carries an image onto the row", () =>
    givenEvents([])
    ->whenEvent(
      CategoryAdded({categoryId: "c1", name: "Electronics", imageUrl: "/uploads/cat/c1.svg"}),
    )
    ->thenStateWithId(
      "c1",
      {
        categoryId: "c1",
        name: "Electronics",
        archived: false,
        imageUrl: "/uploads/cat/c1.svg",
      },
    )
  )

  test("CategoryImageChanged replaces the image", () =>
    givenEvents([
      CategoryAdded({categoryId: "c1", name: "Electronics", imageUrl: "/uploads/cat/old.svg"}),
    ])
    ->whenEvent(CategoryImageChanged({categoryId: "c1", imageUrl: "/uploads/cat/new.svg"}))
    ->thenStateWithId(
      "c1",
      {
        categoryId: "c1",
        name: "Electronics",
        archived: false,
        imageUrl: "/uploads/cat/new.svg",
      },
    )
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
