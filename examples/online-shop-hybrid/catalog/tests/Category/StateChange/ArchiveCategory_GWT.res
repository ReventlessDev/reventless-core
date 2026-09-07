@@reventless.gwt

describe("ArchiveCategory StateChangeSlice", () => {
  test("archive on non-existent category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(ArchiveCategory({categoryId: "c1"}))
    ->thenError(CategoryNotFound)
  )

  test("archive on active category produces CategoryArchived", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(ArchiveCategory({categoryId: "c1"}))
    ->thenEvent(CategoryArchived({categoryId: "c1"}))
  )

  test("archive on archived category produces no events (idempotent)", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(ArchiveCategory({categoryId: "c1"}))
    ->thenNoEvent
  )
})
