@@reventless.gwt

open Catalog_Examples

describe("UnarchiveCategory StateChangeSlice", () => {
  // scenario-id: 2215623d-ee93-4df0-a802-0811a5941778
  test("unarchive on non-existent category returns CategoryNotFound", () =>
    givenEvents([])->whenCmd(UnarchiveCategory({categoryId: c1}))->thenError(CategoryNotFound)
  )

  // scenario-id: faf278be-f15b-429c-a987-9d4d2553b92b
  test("unarchive on archived category produces CategoryUnarchived", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(UnarchiveCategory({categoryId: c1}))
    ->thenEvent(CategoryUnarchived({categoryId: c1}))
  )

  // scenario-id: 82cba695-9eac-4fb9-8271-22ad3998e61c
  test("unarchive on a listed category produces no events (idempotent)", () =>
    givenEvents([CategoryAdded])->whenCmd(UnarchiveCategory({categoryId: c1}))->thenNoEvent
  )
})

describe("Who may UnarchiveCategory", () => {
  // scenario-id: 10362958-74e3-4580-ae1d-57bc03175e8c
  test("a Merchandiser may unarchive a category", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(UnarchiveCategory({categoryId: c1}))
    ->thenEvent(CategoryUnarchived({categoryId: c1}))
  )

  // scenario-id: f815d052-f252-4ab1-a02c-3646e5e4e819
  test("an Admin may unarchive a category", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(UnarchiveCategory({categoryId: c1}))
    ->thenEvent(CategoryUnarchived({categoryId: c1}))
  )

  // scenario-id: e36fb12b-c88b-4732-a293-8e194a8a7ec5
  test("a shopper may not unarchive a category", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(UnarchiveCategory({categoryId: c1}))
    ->thenRefused
  )

  // scenario-id: a149da17-77e5-4f6a-b2a3-28865bb6f047
  test("an anonymous caller may not unarchive a category", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->asCaller(Caller.anonymous)
    ->whenCmd(UnarchiveCategory({categoryId: c1}))
    ->thenRefused
  )
})
