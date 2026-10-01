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

describe("Who may SetCategoryImage", () => {
  // scenario-id: 49e65046-27fe-4b6b-b195-2c3d987a843c
  test("a Merchandiser may set a category image", () =>
    givenEvents([CategoryAdded])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(SetCategoryImage({categoryId: c1, categoryImage: img}))
    ->thenEvents([
      CategoryImageAttached({categoryId: c1, categoryImage: img}),
      CategoryEffectiveImageChanged({categoryId: c1, categoryImage: img}),
    ])
  )

  // scenario-id: ae0c4ed2-4044-4cdf-908b-30bb75c63d4d
  test("an Admin may set a category image", () =>
    givenEvents([CategoryAdded])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(SetCategoryImage({categoryId: c1, categoryImage: img}))
    ->thenEvents([
      CategoryImageAttached({categoryId: c1, categoryImage: img}),
      CategoryEffectiveImageChanged({categoryId: c1, categoryImage: img}),
    ])
  )

  // scenario-id: 762f7e3f-ccf7-49ba-8695-ce4fa0e0dc17
  test("a shopper may not set a category image", () =>
    givenEvents([CategoryAdded])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(SetCategoryImage({categoryId: c1, categoryImage: img}))
    ->thenRefused
  )

  // scenario-id: b458e1f5-9851-46c4-8f54-70f15cd07363
  test("an anonymous caller may not set a category image", () =>
    givenEvents([CategoryAdded])
    ->asCaller(Caller.anonymous)
    ->whenCmd(SetCategoryImage({categoryId: c1, categoryImage: img}))
    ->thenRefused
  )
})

describe("Who may RemoveCategoryImage", () => {
  // scenario-id: b564e912-d050-404e-b5f2-4414ceb6b3a0
  test("a Merchandiser may remove a category image", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(RemoveCategoryImage({categoryId: c1}))
    ->thenEvents([
      CategoryImageRemoved({categoryId: c1, categoryImage: img}),
      CategoryEffectiveImageChanged({categoryId: c1}),
    ])
  )

  // scenario-id: e2f9e18e-c578-4aa0-8022-505413a40c14
  test("an Admin may remove a category image", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(RemoveCategoryImage({categoryId: c1}))
    ->thenEvents([
      CategoryImageRemoved({categoryId: c1, categoryImage: img}),
      CategoryEffectiveImageChanged({categoryId: c1}),
    ])
  )

  // scenario-id: eb94bf0e-b9b3-4c95-8ff9-04e10d529a76
  test("a shopper may not remove a category image", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(RemoveCategoryImage({categoryId: c1}))
    ->thenRefused
  )

  // scenario-id: d5a1189a-39ca-4621-ad76-f6ad09278de1
  test("an anonymous caller may not remove a category image", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->asCaller(Caller.anonymous)
    ->whenCmd(RemoveCategoryImage({categoryId: c1}))
    ->thenRefused
  )
})

describe("Who may SetCategoryImageAltText", () => {
  // scenario-id: 8416ec6f-0792-4bdc-b86f-13edb493c1d1
  test("a Merchandiser may caption a category image", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(SetCategoryImageAltText({categoryId: c1, altText: bannerAlt}))
    ->thenEvent(CategoryImageAltTextSet({categoryId: c1, categoryImage: img, altText: bannerAlt}))
  )

  // scenario-id: 58b0db4c-6d8e-4e45-9a31-e275f54e587b
  test("an Admin may caption a category image", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(SetCategoryImageAltText({categoryId: c1, altText: bannerAlt}))
    ->thenEvent(CategoryImageAltTextSet({categoryId: c1, categoryImage: img, altText: bannerAlt}))
  )

  // scenario-id: a09f3b50-7fe2-4be5-94ed-412810079c52
  test("a shopper may not caption a category image", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(SetCategoryImageAltText({categoryId: c1, altText: bannerAlt}))
    ->thenRefused
  )

  // scenario-id: 3379e5bc-7c2e-4ea4-b174-5572e12edab6
  test("an anonymous caller may not caption a category image", () =>
    givenEvents([CategoryAdded, CategoryImageAttached({categoryImage: img})])
    ->asCaller(Caller.anonymous)
    ->whenCmd(SetCategoryImageAltText({categoryId: c1, altText: bannerAlt}))
    ->thenRefused
  )
})
