@@reventless.gwt

open Catalog_Examples

describe("AddCategory StateChangeSlice", () => {
  // scenario-id: 0d4ea55a-3b47-4917-a8d6-b6881040e2ee
  test("empty event log produces CategoryAdded", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: c1, name: electronics}))
    ->thenEvent(CategoryAdded({categoryId: c1, name: electronics}))
  )

  // scenario-id: ff090764-a13d-4cf3-8a84-f789b359d5ba
  test("an image given at creation travels on CategoryAdded", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: c1, name: electronics}))
    ->thenEvent(CategoryAdded({categoryId: c1, name: electronics}))
  )

  // scenario-id: 87c8cc26-528b-4c19-b02d-2a57b7a02c56
  test("existing category returns CategoryAlreadyExists", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(AddCategory({categoryId: c1, name: electronics}))
    ->thenError(CategoryAlreadyExists)
  )

  // scenario-id: 51e1827c-4acc-4125-8a2e-c9d0e7162f26
  test("archived category still rejects new AddCategory", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(AddCategory({categoryId: c1, name: electronics}))
    ->thenError(CategoryAlreadyExists)
  )
})

describe("Who may AddCategory", () => {
  // scenario-id: c458d10e-0c65-4480-b801-99d0e3a643aa
  test("a Merchandiser may add a category", () =>
    givenEvents([])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(AddCategory({categoryId: c1, name: electronics}))
    ->thenEvent(CategoryAdded({categoryId: c1, name: electronics}))
  )

  // scenario-id: 37154da1-4c78-4b77-97ed-0b73e35d5532
  test("an Admin may add a category", () =>
    givenEvents([])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(AddCategory({categoryId: c1, name: electronics}))
    ->thenEvent(CategoryAdded({categoryId: c1, name: electronics}))
  )

  // scenario-id: fd2ec80d-1154-4243-b798-58d25fbcec1b
  test("a shopper may not add a category", () =>
    givenEvents([])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(AddCategory({categoryId: c1, name: electronics}))
    ->thenRefused
  )

  // scenario-id: 25bb6900-8985-4abd-8b21-4052d4e7284e
  test("an anonymous caller may not add a category", () =>
    givenEvents([])
    ->asCaller(Caller.anonymous)
    ->whenCmd(AddCategory({categoryId: c1, name: electronics}))
    ->thenRefused
  )
})
