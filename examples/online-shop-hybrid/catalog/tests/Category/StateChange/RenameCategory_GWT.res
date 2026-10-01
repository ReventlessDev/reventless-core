@@reventless.gwt

open Catalog_Examples

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

describe("Who may RenameCategory", () => {
  // scenario-id: 414ac462-4498-4831-9e48-0ae5212b6d10
  test("a Merchandiser may rename a category", () =>
    givenEvents([CategoryAdded({name: electronics})])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(RenameCategory({categoryId: c1, name: consumerElectronics}))
    ->thenEvent(CategoryRenamed({categoryId: c1, name: consumerElectronics}))
  )

  // scenario-id: 5aa5f1a0-4b27-47a8-a445-312259efdf6c
  test("an Admin may rename a category", () =>
    givenEvents([CategoryAdded({name: electronics})])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(RenameCategory({categoryId: c1, name: consumerElectronics}))
    ->thenEvent(CategoryRenamed({categoryId: c1, name: consumerElectronics}))
  )

  // scenario-id: 10e861cf-ad26-461e-b2c2-04194a34054a
  test("a shopper may not rename a category", () =>
    givenEvents([CategoryAdded({name: electronics})])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(RenameCategory({categoryId: c1, name: consumerElectronics}))
    ->thenRefused
  )

  // scenario-id: c1896219-85d5-463d-9bcd-23fa1484d933
  test("an anonymous caller may not rename a category", () =>
    givenEvents([CategoryAdded({name: electronics})])
    ->asCaller(Caller.anonymous)
    ->whenCmd(RenameCategory({categoryId: c1, name: consumerElectronics}))
    ->thenRefused
  )
})
