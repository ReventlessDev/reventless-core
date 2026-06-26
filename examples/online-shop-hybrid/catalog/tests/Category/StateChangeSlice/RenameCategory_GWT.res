@@reventless.gwt

describe("RenameCategory StateChangeSlice", () => {
  test("rename on non-existent category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(RenameCategory({categoryId: "c1", name: "Consumer Electronics"}))
    ->thenError(CategoryNotFound)
  )

  test("rename on active category produces CategoryRenamed", () =>
    givenEvents([CategoryAdded({name: "Electronics"})])
    ->whenCmd(RenameCategory({categoryId: "c1", name: "Consumer Electronics"}))
    ->thenEvent(CategoryRenamed({categoryId: "c1", name: "Consumer Electronics"}))
  )

  test("rename to same name produces no events (idempotent)", () =>
    givenEvents([CategoryAdded({name: "Electronics"})])
    ->whenCmd(RenameCategory({categoryId: "c1", name: "Electronics"}))
    ->thenNoEvent
  )

  test("rename on archived category returns CategoryAlreadyArchived", () =>
    givenEvents([CategoryAdded({name: "Electronics"}), CategoryArchived])
    ->whenCmd(RenameCategory({categoryId: "c1", name: "X"}))
    ->thenError(CategoryAlreadyArchived)
  )
})
