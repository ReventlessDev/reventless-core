@@reventless.gwt

open Catalog_Examples

describe("ArchiveCategory StateChangeSlice", () => {
  // scenario-id: 0284f6d2-62f7-48b2-86d6-68a3277b1987
  test("archive on non-existent category returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenError(CategoryNotFound)
  )

  // scenario-id: 997c039b-f33a-4f49-bdc5-51cfca670048
  test("archive on active category produces CategoryArchived", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenEvent(CategoryArchived({categoryId: c1}))
  )

  // scenario-id: 1ac32901-8350-43c5-b379-df21a72f5e77
  test("archive on archived category produces no events (idempotent)", () =>
    givenEvents([CategoryAdded, CategoryArchived])
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenNoEvent
  )
})

describe("Who may ArchiveCategory", () => {
  // scenario-id: 6c720a08-7706-44dc-9c3c-6cf8b88076ce
  test("a Merchandiser may archive a category", () =>
    givenEvents([CategoryAdded])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenEvent(CategoryArchived({categoryId: c1}))
  )

  // scenario-id: fdf2d54d-2db9-4ebc-a875-6ab8efbd2b5a
  test("an Admin may archive a category", () =>
    givenEvents([CategoryAdded])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenEvent(CategoryArchived({categoryId: c1}))
  )

  // scenario-id: 2527b3f1-a0fd-4d9a-a194-8b245b8ed9af
  test("a shopper may not archive a category", () =>
    givenEvents([CategoryAdded])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenRefused
  )

  // scenario-id: c48b1b53-1710-49a8-9016-963b9324bb64
  test("an anonymous caller may not archive a category", () =>
    givenEvents([CategoryAdded])
    ->asCaller(Caller.anonymous)
    ->whenCmd(ArchiveCategory({categoryId: c1}))
    ->thenRefused
  )
})
