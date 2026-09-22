@@reventless.gwt

open CatalogExamples

describe("RenameCategory StateChangeSlice", () => {
  // scenario-id: efd7fb0e-ab16-43f6-8a13-7ea63c548e5d
  test("rename on non-existent category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(RenameCategory({categoryId: c1, name: consumerElectronics}))
    ->thenError(CategoryNotFound)
  )

  // scenario-id: 8e49986c-5316-463a-b698-28a5b06ae0be
  test("rename on active category produces CategoryRenamed", () =>
    givenEvents([CategoryAdded({name: electronics})])
    ->whenCmd(RenameCategory({categoryId: c1, name: consumerElectronics}))
    ->thenEvent(CategoryRenamed({categoryId: c1, name: consumerElectronics}))
  )

  // scenario-id: ba5921c7-7f6c-4518-9039-3e87c87753e9
  test("rename to same name produces no events (idempotent)", () =>
    givenEvents([CategoryAdded({name: electronics})])
    ->whenCmd(RenameCategory({categoryId: c1, name: electronics}))
    ->thenNoEvent
  )

  // scenario-id: a53bc127-b09d-4146-9301-3f0405ae079a
  test("rename on archived category returns CategoryAlreadyArchived", () =>
    givenEvents([CategoryAdded({name: electronics}), CategoryArchived])
    ->whenCmd(RenameCategory({categoryId: c1, name: "X"}))
    ->thenError(CategoryAlreadyArchived)
  )
})
