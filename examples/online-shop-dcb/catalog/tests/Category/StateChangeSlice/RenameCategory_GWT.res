@@reventless.gwt

describe("RenameCategory StateChangeSlice", () => {
  test("non-existent category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(RenameCategory({categoryId: "c1", name: "Consumer Electronics"}))
    ->thenError(CategoryNotFound)
  )

  test("existing active category produces CategoryRenamed", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(RenameCategory({categoryId: "c1", name: "Consumer Electronics"}))
    ->thenEvent(CategoryRenamed({categoryId: "c1", name: "Consumer Electronics"}))
  )

  test("archived category returns CategoryAlreadyArchived", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(RenameCategory({categoryId: "c1", name: "Consumer Electronics"}))
    ->thenError(CategoryAlreadyArchived)
  )
})
