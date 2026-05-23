@@reventless.gwt

describe("RenameCategory StateChangeSlice", () => {
  test("non-existent category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(RenameCategory({categoryId: "c1", name: "Consumer Electronics"}))
    ->thenError(CategoryNotFound)
  )

  test("existing active category produces CategoryRenamed", () =>
    givenEvents([CategoryAdded({name: "Electronics"})])
    ->whenCmd(RenameCategory({categoryId: "c1", name: "Consumer Electronics"}))
    ->thenEvent(CategoryRenamed({categoryId: "c1", name: "Consumer Electronics"}))
  )

  test("renaming to the current name produces no events (idempotent)", () =>
    givenEvents([CategoryAdded({name: "Electronics"})])
    ->whenCmd(RenameCategory({categoryId: "c1", name: "Electronics"}))
    ->thenNoEvent
  )

  test("archived category returns CategoryAlreadyArchived", () =>
    givenEvents([CategoryAdded({name: "Electronics"}), CategoryArchived])
    ->whenCmd(RenameCategory({categoryId: "c1", name: "Consumer Electronics"}))
    ->thenError(CategoryAlreadyArchived)
  )
})
