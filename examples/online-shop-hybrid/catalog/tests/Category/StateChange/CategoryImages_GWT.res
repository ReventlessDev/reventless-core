// The host's own rules; the set's are the trait's, asserted in
// `CategoryImagesConformance_GWT.res`.

@@reventless.gwt

let cid = CategoryId.make

let img = "/uploads/cat/c1.svg"
let banner = "/uploads/cat/c1-banner.svg"

describe("CategoryImages StateChangeSlice", () => {
  test("unknown category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(SetCategoryImage({categoryId: cid("c1"), categoryImage: img}))
    ->thenError(CategoryNotFound)
  )

  test("a listed category takes an image", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(SetCategoryImage({categoryId: cid("c1"), categoryImage: img}))
    ->thenEvents([
      CategoryImageAttached({categoryId: cid("c1"), categoryImage: img}),
      CategoryEffectiveImageChanged({categoryId: cid("c1"), categoryImage: img}),
    ])
  )

  // The bounded cardinality, through this host: a second image does not join the
  // first, it takes its place, and the log says so in two facts rather than
  // leaving a reader to infer a replacement from a set that never grew.
  test("a second image replaces the first", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->whenCmd(SetCategoryImage({categoryId: cid("c1"), categoryImage: banner}))
    ->thenEvents([
      CategoryImageRemoved({categoryId: cid("c1"), categoryImage: img}),
      CategoryImageAttached({categoryId: cid("c1"), categoryImage: banner}),
      CategoryEffectiveImageChanged({categoryId: cid("c1"), categoryImage: banner}),
    ])
  )

  test("a listed category releases its image", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->whenCmd(RemoveCategoryImage({categoryId: cid("c1")}))
    ->thenEvents([
      CategoryImageRemoved({categoryId: cid("c1"), categoryImage: img}),
      CategoryEffectiveImageChanged({categoryId: cid("c1")}),
    ])
  )

  test("a listed category captions its image", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->whenCmd(SetCategoryImageAltText({categoryId: cid("c1"), altText: "banner"}))
    ->thenEvent(
      CategoryImageAltTextSet({categoryId: cid("c1"), categoryImage: img, altText: "banner"}),
    )
  )

  test("archived category returns CategoryAlreadyArchived", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(SetCategoryImage({categoryId: cid("c1"), categoryImage: img}))
    ->thenError(CategoryAlreadyArchived)
  )

  test("an unarchived category takes an image again", () =>
    givenEvents([CategoryAdded, CategoryArchived, CategoryUnarchived])
    ->whenCmd(SetCategoryImage({categoryId: cid("c1"), categoryImage: img}))
    ->thenEvents([
      CategoryImageAttached({categoryId: cid("c1"), categoryImage: img}),
      CategoryEffectiveImageChanged({categoryId: cid("c1"), categoryImage: img}),
    ])
  )
})
