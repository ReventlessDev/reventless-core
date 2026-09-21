@@reventless.gwt

let cid = CategoryId.make

describe("ArchiveCategory StateChangeSlice", () => {
  test("archive on non-existent category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(ArchiveCategory({categoryId: cid("c1")}))
    ->thenError(CategoryNotFound)
  )

  test("archive on active category produces CategoryArchived", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(ArchiveCategory({categoryId: cid("c1")}))
    ->thenEvent(CategoryArchived({categoryId: cid("c1")}))
  )

  test("archive on archived category produces no events (idempotent)", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(ArchiveCategory({categoryId: cid("c1")}))
    ->thenNoEvent
  )
})
