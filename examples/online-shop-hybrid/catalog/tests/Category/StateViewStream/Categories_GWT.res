@@reventless.gwt

open CatalogExamples

// Literals throughout: the lifecycle check harvests `shelfStatus` from the
// sidecar the PPX writes, and it can only read what is spelled out.

// Every event a projection GWT feeds carries the harness's fixed producer time,
// so every trail entry below is stamped with that one instant.
let trail = (states: array<shelfStatus>) =>
  states->Array.map((state): Reventless.Lifecycle.Trail.entry<shelfStatus> => {
    state,
    at: "1970-01-01T00:00:00Z",
  })

describe("Categories StateViewSliceStream", () => {
  // scenario-id: 6962e406-89f2-4b74-8d76-f1aa8a899314
  test("CategoryAdded creates a row with no image", () =>
    givenEvents([])
    ->whenEvent(CategoryAdded({categoryId: c1, name: electronics}))
    ->thenStateWithId(
      "c1",
      {categoryId: c1, name: electronics, shelfStatus: Listed, trail: trail([Listed])},
    )
  )

  // scenario-id: 6f40a8ca-58c9-4b37-8d81-a10600af09ff
  test("CategoryImageAttached fills the image", () =>
    givenEvents([CategoryAdded({categoryId: c1, name: electronics})])
    ->whenEvent(CategoryImageAttached({categoryId: c1, categoryImage}))
    ->thenStateWithId(
      "c1",
      {
        categoryId: c1,
        name: electronics,
        shelfStatus: Listed,
        trail: trail([Listed]),
        categoryImage: {ref: "/uploads/cat/c1.svg"},
      },
    )
  )

  // The two facts of a replacement, in the order the slice decides them. The
  // removal names the old reference, so the arm that would otherwise blank the
  // row leaves the one just attached alone.
  // scenario-id: 24e86782-4e70-4264-8ae9-375d7b714eaa
  test("a replacement's removal leaves the new image standing", () =>
    givenEvents([
      CategoryAdded({categoryId: c1, name: electronics}),
      CategoryImageAttached({categoryId: c1, categoryImage}),
      CategoryImageRemoved({categoryId: c1, categoryImage}),
    ])
    ->whenEvent(
      CategoryImageAttached({categoryId: c1, categoryImage: "/uploads/cat/c1-banner.svg"}),
    )
    ->thenStateWithId(
      "c1",
      {
        categoryId: c1,
        name: electronics,
        shelfStatus: Listed,
        trail: trail([Listed]),
        categoryImage: {ref: "/uploads/cat/c1-banner.svg"},
      },
    )
  )

  // scenario-id: 00716b86-3206-4c9c-a542-6d6f2e5dcc42
  test("CategoryImageRemoved empties the image, caption and all", () =>
    givenEvents([
      CategoryAdded({categoryId: c1, name: electronics}),
      CategoryImageAttached({categoryId: c1, categoryImage}),
      CategoryImageAltTextSet({
        categoryId: c1,
        categoryImage,
        altText: bannerAlt,
      }),
    ])
    ->whenEvent(CategoryImageRemoved({categoryId: c1, categoryImage}))
    ->thenStateWithId(
      "c1",
      {categoryId: c1, name: electronics, shelfStatus: Listed, trail: trail([Listed])},
    )
  )

  // scenario-id: 5fb60264-8de4-40ce-95a9-0a5fabd9ef35
  test("CategoryImageAltTextSet captions the image", () =>
    givenEvents([
      CategoryAdded({categoryId: c1, name: electronics}),
      CategoryImageAttached({categoryId: c1, categoryImage}),
    ])
    ->whenEvent(
      CategoryImageAltTextSet({
        categoryId: c1,
        categoryImage,
        altText: bannerAlt,
      }),
    )
    ->thenStateWithId(
      "c1",
      {
        categoryId: c1,
        name: electronics,
        shelfStatus: Listed,
        trail: trail([Listed]),
        categoryImage: {ref: "/uploads/cat/c1.svg", altText: "banner"},
      },
    )
  )

  // scenario-id: 434c35f4-ce79-4f7d-9780-0ee94d170471
  test("CategoryRenamed updates the name", () =>
    givenEvents([CategoryAdded({categoryId: c1, name: electronics})])
    ->whenEvent(CategoryRenamed({categoryId: c1, name: consumerElectronics}))
    ->thenStateWithId(
      "c1",
      {
        categoryId: c1,
        name: consumerElectronics,
        shelfStatus: Listed,
        trail: trail([Listed]),
      },
    )
  )

  // scenario-id: a4b04d16-47f5-48e7-9415-17016308599d
  test("CategoryArchived sets archived flag", () =>
    givenEvents([CategoryAdded({categoryId: c1, name: electronics})])
    ->whenEvent(CategoryArchived({categoryId: c1}))
    ->thenStateWithId(
      "c1",
      {
        categoryId: c1,
        name: electronics,
        shelfStatus: Archived,
        trail: trail([Listed, Archived]),
      },
    )
  )

  // The way back, so the lifecycle harvest knows an unarchived category is listed.
  // scenario-id: 0b7f98dd-64db-46f2-9d7e-c762a3c78d91
  test("CategoryUnarchived returns it to the catalog", () =>
    givenEvents([
      CategoryAdded({categoryId: c1, name: electronics}),
      CategoryArchived({categoryId: c1}),
    ])
    ->whenEvent(CategoryUnarchived({categoryId: c1}))
    ->thenStateWithId(
      "c1",
      {
        categoryId: c1,
        name: electronics,
        shelfStatus: Listed,
        trail: trail([Listed, Archived, Listed]),
      },
    )
  )
})
