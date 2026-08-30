@@reventless.gwt

describe("AddCategory StateChangeSlice", () => {
  test("empty event log produces CategoryAdded", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: "c1", name: "Electronics"}))
    ->thenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"}))
  )

  test("an image given at creation travels on CategoryAdded", () =>
    givenEvents([])
    ->whenCmd(
      AddCategory({categoryId: "c1", name: "Electronics"}),
    )
    ->thenEvent(
      CategoryAdded({categoryId: "c1", name: "Electronics"}),
    )
  )

  test("existing category returns CategoryAlreadyExists", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(AddCategory({categoryId: "c1", name: "Electronics"}))
    ->thenError(CategoryAlreadyExists)
  )

  test("archived category still rejects new AddCategory", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(AddCategory({categoryId: "c1", name: "Electronics"}))
    ->thenError(CategoryAlreadyExists)
  )
})
