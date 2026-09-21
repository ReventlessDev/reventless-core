@@reventless.gwt

let catId = CategoryId.make

describe("AddCategory StateChangeSlice", () => {
  test("empty event log produces CategoryAdded", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: catId("c1"), name: "Electronics"}))
    ->thenEvent(CategoryAdded({categoryId: catId("c1"), name: "Electronics"}))
  )

  test("existing category returns CategoryAlreadyExists", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(AddCategory({categoryId: catId("c1"), name: "Electronics"}))
    ->thenError(CategoryAlreadyExists)
  )

  test("archived category still rejects new AddCategory", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(AddCategory({categoryId: catId("c1"), name: "Electronics"}))
    ->thenError(CategoryAlreadyExists)
  )
})
