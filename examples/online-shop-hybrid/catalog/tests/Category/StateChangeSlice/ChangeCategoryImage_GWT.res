@@reventless.gwt

describe("ChangeCategoryImage StateChangeSlice", () => {
  test("unknown category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeCategoryImage({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}))
    ->thenError(CategoryNotFound)
  )

  test("a category with no image accepts its first one", () =>
    givenEvents([CategoryAdded({})])
    ->whenCmd(ChangeCategoryImage({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}))
    ->thenEvent(CategoryImageChanged({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}))
  )

  test("replacing an existing image emits the change", () =>
    givenEvents([CategoryAdded({categoryImage: "/uploads/cat/old.svg"})])
    ->whenCmd(ChangeCategoryImage({categoryId: "c1", categoryImage: "/uploads/cat/new.svg"}))
    ->thenEvent(CategoryImageChanged({categoryId: "c1", categoryImage: "/uploads/cat/new.svg"}))
  )

  test("the same image appends nothing", () =>
    givenEvents([CategoryAdded({categoryImage: "/uploads/cat/c1.svg"})])
    ->whenCmd(ChangeCategoryImage({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}))
    ->thenNoEvent
  )

  test("the same image appends nothing after an earlier change", () =>
    givenEvents([
      CategoryAdded({categoryImage: "/uploads/cat/old.svg"}),
      CategoryImageChanged({categoryImage: "/uploads/cat/new.svg"}),
    ])
    ->whenCmd(ChangeCategoryImage({categoryId: "c1", categoryImage: "/uploads/cat/new.svg"}))
    ->thenNoEvent
  )

  test("archived category returns CategoryAlreadyArchived", () =>
    givenEvents([CategoryAdded({}), CategoryArchived])
    ->whenCmd(ChangeCategoryImage({categoryId: "c1", categoryImage: "/uploads/cat/c1.svg"}))
    ->thenError(CategoryAlreadyArchived)
  )
})
