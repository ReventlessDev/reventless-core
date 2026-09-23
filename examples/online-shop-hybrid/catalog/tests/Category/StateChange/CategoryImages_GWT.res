// The host's own rules; the set's are the trait's, asserted in
// `CategoryImagesConformance_GWT.res`.

@@reventless.gwt

open Catalog_Examples

let img = "/uploads/cat/c1.svg"
let banner = "/uploads/cat/c1-banner.svg"

describe("CategoryImages StateChangeSlice", () => {
  // scenario-id: 21efeb6b-e69d-4720-8a98-a86960d2591c
  test("unknown category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(SetCategoryImage({categoryId: c1, categoryImage: img}))
    ->thenError(CategoryNotFound)
  )

  // scenario-id: bd614ce7-7181-428a-b228-a3faf3a21216
  test("a listed category takes an image", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(SetCategoryImage({categoryId: c1, categoryImage: img}))
    ->thenEvents([
      CategoryImageAttached({categoryId: c1, categoryImage: img}),
      CategoryEffectiveImageChanged({categoryId: c1, categoryImage: img}),
    ])
  )

  // The bounded cardinality, through this host: a second image does not join the
  // first, it takes its place, and the log says so in two facts rather than
  // leaving a reader to infer a replacement from a set that never grew.
  // scenario-id: b95168c7-4d51-4721-a29d-d63f0cb1882b
  test("a second image replaces the first", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->whenCmd(SetCategoryImage({categoryId: c1, categoryImage: banner}))
    ->thenEvents([
      CategoryImageRemoved({categoryId: c1, categoryImage: img}),
      CategoryImageAttached({categoryId: c1, categoryImage: banner}),
      CategoryEffectiveImageChanged({categoryId: c1, categoryImage: banner}),
    ])
  )

  // scenario-id: 1337f750-951c-4074-bc4b-a3540811df4c
  test("a listed category releases its image", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->whenCmd(RemoveCategoryImage({categoryId: c1}))
    ->thenEvents([
      CategoryImageRemoved({categoryId: c1, categoryImage: img}),
      CategoryEffectiveImageChanged({categoryId: c1}),
    ])
  )

  // scenario-id: 2fe6898f-3be6-4d6d-825e-6bbf9b98bcf2
  test("a listed category captions its image", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->whenCmd(SetCategoryImageAltText({categoryId: c1, altText: bannerAlt}))
    ->thenEvent(CategoryImageAltTextSet({categoryId: c1, categoryImage: img, altText: bannerAlt}))
  )

  // scenario-id: 8a1a00e9-150f-4e9e-a9c3-0c7e559d404b
  test("archived category returns CategoryAlreadyArchived", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(SetCategoryImage({categoryId: c1, categoryImage: img}))
    ->thenError(CategoryAlreadyArchived)
  )

  // scenario-id: 3027da1c-50c1-42a8-843c-9532cca8fb3e
  test("an unarchived category takes an image again", () =>
    givenEvents([CategoryAdded, CategoryArchived, CategoryUnarchived])
    ->whenCmd(SetCategoryImage({categoryId: c1, categoryImage: img}))
    ->thenEvents([
      CategoryImageAttached({categoryId: c1, categoryImage: img}),
      CategoryEffectiveImageChanged({categoryId: c1, categoryImage: img}),
    ])
  )
})
