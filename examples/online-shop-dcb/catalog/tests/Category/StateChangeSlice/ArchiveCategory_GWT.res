@@reventless.gwt

describe("ArchiveCategory StateChangeSlice", () => {
  test("non-existent category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(ArchiveCategory({categoryId: "c1"}))
    ->thenError(CategoryNotFound)
  )

  test("existing active category produces CategoryArchived", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(ArchiveCategory({categoryId: "c1"}))
    ->thenEvent(CategoryArchived({categoryId: "c1"}))
  )

  test("already archived category produces no events (idempotent)", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(ArchiveCategory({categoryId: "c1"}))
    ->thenNoEvent
  )
})
