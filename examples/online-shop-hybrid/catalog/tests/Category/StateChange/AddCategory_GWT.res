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
