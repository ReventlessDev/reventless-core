@@reventless.gwt

let catId = CategoryId.make

describe("ArchiveCategory StateChangeSlice", () => {
  test("non-existent category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(ArchiveCategory({categoryId: catId("c1")}))
    ->thenError(CategoryNotFound)
  )

  test("existing active category produces CategoryArchived", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(ArchiveCategory({categoryId: catId("c1")}))
    ->thenEvent(CategoryArchived({categoryId: catId("c1")}))
  )

  test("already archived category produces no events (idempotent)", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(ArchiveCategory({categoryId: catId("c1")}))
    ->thenNoEvent
  )
})
