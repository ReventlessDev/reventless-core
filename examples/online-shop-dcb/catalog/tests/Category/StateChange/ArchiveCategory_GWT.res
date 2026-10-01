@@reventless.gwt

open Catalog_Examples

describe("ArchiveCategory StateChangeSlice", () => {
  // scenario-id: 49ce0e1d-9e21-4883-b59a-86951fd8ff07
  test("non-existent category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenError(CategoryNotFound)
  )

  // scenario-id: b424296a-dd52-469a-90af-76a2a5a6edab
  test("existing active category produces CategoryArchived", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenEvent(CategoryArchived({categoryId: c1}))
  )

  // scenario-id: ad141ffb-7abc-4fbc-8450-195851a2e44d
  test("already archived category produces no events (idempotent)", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenNoEvent
  )
})

describe("Who may ArchiveCategory", () => {
  // scenario-id: 265a155c-74e4-4435-a4f3-e8c7f73f6282
  test("an Admin may archive a category", () =>
    givenEvents([CategoryAdded])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenEvent(CategoryArchived({categoryId: c1}))
  )

  // scenario-id: 63df971a-e114-4d8e-b2cf-06f7844a2c98
  test("a shopper may not archive a category", () =>
    givenEvents([CategoryAdded])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenRefused
  )

  // scenario-id: 1ce2fe61-7c2c-44ee-9f2d-de0e6070242f
  test("an anonymous caller may not archive a category", () =>
    givenEvents([CategoryAdded])
    ->asCaller(Caller.anonymous)
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenRefused
  )
})
