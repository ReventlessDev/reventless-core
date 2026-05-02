@@reventless.gwt

describe("Category Behavior", () => {
  test("Add on new aggregate produces Added", () =>
    givenEvents([])
    ->whenCmd(Add({name: "Electronics"}))
    ->thenEvent(Added({name: "Electronics"}))
  )

  test("Add on existing aggregate returns CategoryAlreadyExists", () =>
    givenEvents([Added({name: "Electronics"})])
    ->whenCmd(Add({name: "Electronics 2"}))
    ->thenError(CategoryAlreadyExists)
  )

  test("Rename on non-existent aggregate returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(Rename({name: "New Name"}))
    ->thenError(CategoryNotFound)
  )

  test("Rename on active category produces Renamed", () =>
    givenEvents([Added({name: "Electronics"})])
    ->whenCmd(Rename({name: "Consumer Electronics"}))
    ->thenEvent(Renamed({name: "Consumer Electronics"}))
  )

  test("Rename to same name produces no events (idempotent)", () =>
    givenEvents([Added({name: "Electronics"})])
    ->whenCmd(Rename({name: "Electronics"}))
    ->thenNoEvent
  )

  test("Rename on archived category returns CategoryAlreadyArchived", () =>
    givenEvents([Added({name: "Electronics"}), Archived])
    ->whenCmd(Rename({name: "New Name"}))
    ->thenError(CategoryAlreadyArchived)
  )

  test("Archive on active category produces Archived", () =>
    givenEvents([Added({name: "Electronics"})])
    ->whenCmd(Archive)
    ->thenEvent(Archived)
  )

  test("Archive on archived category produces no events (idempotent)", () =>
    givenEvents([Added({name: "Electronics"}), Archived])
    ->whenCmd(Archive)
    ->thenNoEvent
  )
})
