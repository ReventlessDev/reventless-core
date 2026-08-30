// The host's own rules; the set's are the trait's, asserted in
// `CategoryImagesConformance_GWT.res`.

@@reventless.gwt

let img = "/uploads/cat/c1.svg"

describe("CategoryImages StateChangeSlice", () => {
  test("unknown category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(AttachCategoryImage({categoryId: "c1", categoryImage: img}))
    ->thenError(CategoryNotFound)
  )

  test("a listed category takes attachments", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(AttachCategoryImage({categoryId: "c1", categoryImage: img}))
    ->thenEvent(CategoryImageAttached({categoryId: "c1", categoryImage: img}))
  )

  test("a listed category releases them", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->whenCmd(RemoveCategoryImage({categoryId: "c1", categoryImage: img}))
    ->thenEvent(CategoryImageRemoved({categoryId: "c1", categoryImage: img}))
  )

  test("a listed category chooses its primary", () =>
    givenEvents([
      CategoryAdded,
      CategoryImageAttached({categoryImage: img}),
      CategoryImageAttached({categoryImage: "/uploads/cat/c1-banner.svg"}),
    ])
    ->whenCmd(SetPrimaryCategoryImage({categoryId: "c1", categoryImage: "/uploads/cat/c1-banner.svg"}))
    ->thenEvent(CategoryPrimaryImageSet({categoryId: "c1", categoryImage: "/uploads/cat/c1-banner.svg"}))
  )

  test("a listed category captions a member", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->whenCmd(SetCategoryImageAltText({categoryId: "c1", categoryImage: img, altText: "banner"}))
    ->thenEvent(CategoryImageAltTextSet({categoryId: "c1", categoryImage: img, altText: "banner"}))
  )

  test("archived category returns CategoryAlreadyArchived", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(AttachCategoryImage({categoryId: "c1", categoryImage: img}))
    ->thenError(CategoryAlreadyArchived)
  )

  test("an unarchived category takes attachments again", () =>
    givenEvents([CategoryAdded, CategoryArchived, CategoryUnarchived])
    ->whenCmd(AttachCategoryImage({categoryId: "c1", categoryImage: img}))
    ->thenEvent(CategoryImageAttached({categoryId: "c1", categoryImage: img}))
  )
})
