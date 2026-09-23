@@reventless.gwt

open Catalog_Examples

describe("AddCategory StateChangeSlice", () => {
  // scenario-id: 47177361-8d6c-4779-a480-205c15f81cba
  test("empty event log produces CategoryAdded", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: c1, name: electronics}))
    ->thenEvent(CategoryAdded({categoryId: c1, name: electronics}))
  )

  // scenario-id: f992f21a-5262-460d-8cb5-525cb1f47535
  test("existing category returns CategoryAlreadyExists", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(AddCategory({categoryId: c1, name: electronics}))
    ->thenError(CategoryAlreadyExists)
  )

  // scenario-id: 2876b32e-3cf4-43e2-94b2-849a4b6ec1ef
  test("archived category still rejects new AddCategory", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(AddCategory({categoryId: c1, name: electronics}))
    ->thenError(CategoryAlreadyExists)
  )
})
