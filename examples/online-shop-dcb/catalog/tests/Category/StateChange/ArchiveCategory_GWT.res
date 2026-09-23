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
