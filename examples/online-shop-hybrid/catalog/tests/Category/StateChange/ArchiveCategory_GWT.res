@@reventless.gwt

open CatalogExamples

describe("ArchiveCategory StateChangeSlice", () => {
  // scenario-id: 0284f6d2-62f7-48b2-86d6-68a3277b1987
  test("archive on non-existent category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenError(CategoryNotFound)
  )

  // scenario-id: 997c039b-f33a-4f49-bdc5-51cfca670048
  test("archive on active category produces CategoryArchived", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenEvent(CategoryArchived({categoryId: c1}))
  )

  // scenario-id: 1ac32901-8350-43c5-b379-df21a72f5e77
  test("archive on archived category produces no events (idempotent)", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenNoEvent
  )
})
