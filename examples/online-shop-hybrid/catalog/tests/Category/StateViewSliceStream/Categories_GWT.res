@@reventless.gwt

// Literals throughout: the lifecycle check harvests `shelfStatus` from the
// sidecar the PPX writes, and it can only read what is spelled out.
describe("Categories StateViewSliceStream", () => {
  test("CategoryAdded creates a row with no image", () =>
    givenEvents([])
    ->whenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"}))
    ->thenStateWithId("c1", {categoryId: "c1", name: "Electronics", shelfStatus: Listed})
  )

  test("CategoryImageAttached fills the image", () =>
    givenEvents([CategoryAdded({categoryId: "c1", name: "Electronics"})])
    ->whenEvent(CategoryImageAttached({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}))
    ->thenStateWithId(
      "c1",
      {
        categoryId: "c1",
        name: "Electronics",
        shelfStatus: Listed,
        categoryImage: "/uploads/cat/c1.svg",
      },
    )
  )

  // The two facts of a replacement, in the order the slice decides them. The
  // removal names the old reference, so the arm that would otherwise blank the
  // row leaves the one just attached alone.
  test("a replacement's removal leaves the new image standing", () =>
    givenEvents([
      CategoryAdded({categoryId: "c1", name: "Electronics"}),
      CategoryImageAttached({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}),
      CategoryImageRemoved({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}),
    ])
    ->whenEvent(
      CategoryImageAttached({categoryId: "c1", categoryImage: "/uploads/cat/c1-banner.svg"}),
    )
    ->thenStateWithId(
      "c1",
      {
        categoryId: "c1",
        name: "Electronics",
        shelfStatus: Listed,
        categoryImage: "/uploads/cat/c1-banner.svg",
      },
    )
  )

  test("CategoryImageRemoved empties the image and its caption", () =>
    givenEvents([
      CategoryAdded({categoryId: "c1", name: "Electronics"}),
      CategoryImageAttached({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}),
      CategoryImageAltTextSet({
        categoryId: "c1",
        categoryImage: "/uploads/cat/c1.svg",
        altText: "banner",
      }),
    ])
    ->whenEvent(CategoryImageRemoved({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}))
    ->thenStateWithId("c1", {categoryId: "c1", name: "Electronics", shelfStatus: Listed})
  )

  test("CategoryImageAltTextSet captions the image", () =>
    givenEvents([
      CategoryAdded({categoryId: "c1", name: "Electronics"}),
      CategoryImageAttached({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}),
    ])
    ->whenEvent(
      CategoryImageAltTextSet({
        categoryId: "c1",
        categoryImage: "/uploads/cat/c1.svg",
        altText: "banner",
      }),
    )
    ->thenStateWithId(
      "c1",
      {
        categoryId: "c1",
        name: "Electronics",
        shelfStatus: Listed,
        categoryImage: "/uploads/cat/c1.svg",
        categoryImageAltText: "banner",
      },
    )
  )

  test("CategoryRenamed updates the name", () =>
    givenEvents([CategoryAdded({categoryId: "c1", name: "Electronics"})])
    ->whenEvent(CategoryRenamed({categoryId: "c1", name: "Consumer Electronics"}))
    ->thenStateWithId("c1", {categoryId: "c1", name: "Consumer Electronics", shelfStatus: Listed})
  )

  test("CategoryArchived sets archived flag", () =>
    givenEvents([CategoryAdded({categoryId: "c1", name: "Electronics"})])
    ->whenEvent(CategoryArchived({categoryId: "c1"}))
    ->thenStateWithId("c1", {categoryId: "c1", name: "Electronics", shelfStatus: Archived})
  )

  // The way back, so the lifecycle harvest knows an unarchived category is listed.
  test("CategoryUnarchived returns it to the catalog", () =>
    givenEvents([
      CategoryAdded({categoryId: "c1", name: "Electronics"}),
      CategoryArchived({categoryId: "c1"}),
    ])
    ->whenEvent(CategoryUnarchived({categoryId: "c1"}))
    ->thenStateWithId("c1", {categoryId: "c1", name: "Electronics", shelfStatus: Listed})
  )
})
