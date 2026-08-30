@@reventless.gwt

// Literals throughout: the lifecycle check harvests `shelfStatus` from the
// sidecar the PPX writes, and it can only read what is spelled out.
describe("Categories StateViewSliceStream", () => {
  test("CategoryAdded creates a row with an empty set", () =>
    givenEvents([])
    ->whenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"}))
    ->thenStateWithId(
      "c1",
      {categoryId: "c1", name: "Electronics", shelfStatus: Listed, categoryImages: []},
    )
  )

  test("the first CategoryImageAttached becomes the primary", () =>
    givenEvents([CategoryAdded({categoryId: "c1", name: "Electronics"})])
    ->whenEvent(CategoryImageAttached({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}))
    ->thenStateWithId(
      "c1",
      {
        categoryId: "c1",
        name: "Electronics",
        shelfStatus: Listed,
        categoryImage: "/uploads/cat/c1.svg",
        categoryImages: [{categoryImage: "/uploads/cat/c1.svg"}],
      },
    )
  )

  test("CategoryPrimaryImageSet chooses the primary", () =>
    givenEvents([
      CategoryAdded({categoryId: "c1", name: "Electronics"}),
      CategoryImageAttached({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}),
      CategoryImageAttached({categoryId: "c1", categoryImage: "/uploads/cat/c1-banner.svg"}),
    ])
    ->whenEvent(CategoryPrimaryImageSet({categoryId: "c1", categoryImage: "/uploads/cat/c1-banner.svg"}))
    ->thenStateWithId(
      "c1",
      {
        categoryId: "c1",
        name: "Electronics",
        shelfStatus: Listed,
        categoryImage: "/uploads/cat/c1-banner.svg",
        categoryImages: [
          {categoryImage: "/uploads/cat/c1.svg"},
          {categoryImage: "/uploads/cat/c1-banner.svg"},
        ],
      },
    )
  )

  test("removing the primary falls back to the first remaining", () =>
    givenEvents([
      CategoryAdded({categoryId: "c1", name: "Electronics"}),
      CategoryImageAttached({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}),
      CategoryImageAttached({categoryId: "c1", categoryImage: "/uploads/cat/c1-banner.svg"}),
      CategoryPrimaryImageSet({categoryId: "c1", categoryImage: "/uploads/cat/c1-banner.svg"}),
    ])
    ->whenEvent(CategoryImageRemoved({categoryId: "c1", categoryImage: "/uploads/cat/c1-banner.svg"}))
    ->thenStateWithId(
      "c1",
      {
        categoryId: "c1",
        name: "Electronics",
        shelfStatus: Listed,
        categoryImage: "/uploads/cat/c1.svg",
        categoryImages: [{categoryImage: "/uploads/cat/c1.svg"}],
      },
    )
  )

  test("CategoryImageAltTextSet captions one member", () =>
    givenEvents([
      CategoryAdded({categoryId: "c1", name: "Electronics"}),
      CategoryImageAttached({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}),
    ])
    ->whenEvent(
      CategoryImageAltTextSet({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg", altText: "banner"}),
    )
    ->thenStateWithId(
      "c1",
      {
        categoryId: "c1",
        name: "Electronics",
        shelfStatus: Listed,
        categoryImage: "/uploads/cat/c1.svg",
        categoryImages: [{categoryImage: "/uploads/cat/c1.svg", altText: "banner"}],
      },
    )
  )

  test("CategoryRenamed updates the name", () =>
    givenEvents([CategoryAdded({categoryId: "c1", name: "Electronics"})])
    ->whenEvent(CategoryRenamed({categoryId: "c1", name: "Consumer Electronics"}))
    ->thenStateWithId(
      "c1",
      {categoryId: "c1", name: "Consumer Electronics", shelfStatus: Listed, categoryImages: []},
    )
  )

  test("CategoryArchived sets archived flag", () =>
    givenEvents([CategoryAdded({categoryId: "c1", name: "Electronics"})])
    ->whenEvent(CategoryArchived({categoryId: "c1"}))
    ->thenStateWithId(
      "c1",
      {categoryId: "c1", name: "Electronics", shelfStatus: Archived, categoryImages: []},
    )
  )

  // The way back, so the lifecycle harvest knows an unarchived category is listed.
  test("CategoryUnarchived returns it to the catalog", () =>
    givenEvents([
      CategoryAdded({categoryId: "c1", name: "Electronics"}),
      CategoryArchived({categoryId: "c1"}),
    ])
    ->whenEvent(CategoryUnarchived({categoryId: "c1"}))
    ->thenStateWithId(
      "c1",
      {categoryId: "c1", name: "Electronics", shelfStatus: Listed, categoryImages: []},
    )
  )
})
