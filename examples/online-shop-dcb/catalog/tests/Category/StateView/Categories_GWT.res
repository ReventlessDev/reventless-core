@@reventless.gwt

open CatalogExamples

describe("Categories StateViewSlice", () => {
  // scenario-id: 37a3e157-7469-49fe-8b4d-f15f8f2a5cbf
  test("CategoryAdded creates a row", () =>
    givenEvents([])
    ->whenEvent(CategoryAdded({categoryId: c1, name: electronics}))
    ->thenStateWithId("c1", {categoryId: c1, name: electronics, archived: false})
  )

  // scenario-id: 90fbd54b-775c-4b15-b5c8-97daf7097677
  test("CategoryRenamed updates the name", () =>
    givenEvents([CategoryAdded({categoryId: c1, name: electronics})])
    ->whenEvent(CategoryRenamed({categoryId: c1, name: consumerElectronics}))
    ->thenStateWithId("c1", {categoryId: c1, name: consumerElectronics, archived: false})
  )

  // scenario-id: aeb0935e-631a-424f-b8ab-df8276a3dc15
  test("CategoryArchived sets archived flag", () =>
    givenEvents([CategoryAdded({categoryId: c1, name: electronics})])
    ->whenEvent(CategoryArchived({categoryId: c1}))
    ->thenStateWithId("c1", {categoryId: c1, name: electronics, archived: true})
  )
})
