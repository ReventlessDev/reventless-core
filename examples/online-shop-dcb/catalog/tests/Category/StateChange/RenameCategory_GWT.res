@@reventless.gwt

open CatalogExamples

describe("RenameCategory StateChangeSlice", () => {
  // scenario-id: 510ec7f6-4a46-4807-ba06-0cbf43eed254
  test("non-existent category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(RenameCategory({categoryId: c1, name: consumerElectronics}))
    ->thenError(CategoryNotFound)
  )

  // scenario-id: 29ecdd5f-5225-438d-8129-1e3f0a1a978d
  test("existing active category produces CategoryRenamed", () =>
    givenEvents([CategoryAdded({name: electronics})])
    ->whenCmd(RenameCategory({categoryId: c1, name: consumerElectronics}))
    ->thenEvent(CategoryRenamed({categoryId: c1, name: consumerElectronics}))
  )

  // scenario-id: 4fd166f6-e9de-4872-8aa5-e7b89b95288f
  test("renaming to the current name produces no events (idempotent)", () =>
    givenEvents([CategoryAdded({name: electronics})])
    ->whenCmd(RenameCategory({categoryId: c1, name: electronics}))
    ->thenNoEvent
  )

  // scenario-id: a2323466-eec1-42c7-86ad-26a2bcc811d3
  test("archived category returns CategoryAlreadyArchived", () =>
    givenEvents([CategoryAdded({name: electronics}), CategoryArchived])
    ->whenCmd(RenameCategory({categoryId: c1, name: consumerElectronics}))
    ->thenError(CategoryAlreadyArchived)
  )
})
