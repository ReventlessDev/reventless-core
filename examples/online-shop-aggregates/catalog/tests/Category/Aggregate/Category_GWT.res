@@reventless.gwt

open Catalog_Examples

describe("Category Behavior", () => {
  // scenario-id: fb4b109a-87b5-4aa3-a8e2-4fca61d0c050
  test("Add on new aggregate produces Added", () =>
    givenEvents([])
    ->whenCmd(Add({name: electronics}))
    ->thenEvent(Added({name: electronics}))
  )

  // scenario-id: a071dd62-8b9a-4fad-923a-6e740c4995dc
  test("Add on existing aggregate returns CategoryAlreadyExists", () =>
    givenEvents([Added({name: electronics})])
    ->whenCmd(Add({name: "Electronics 2"}))
    ->thenError(CategoryAlreadyExists)
  )

  // scenario-id: 0b4584cf-8399-4511-bedf-422ad0283251
  test("Rename on non-existent aggregate returns CategoryNotFound", () =>
    givenEvents([])
    ->whenCmd(Rename({name: renamedTo}))
    ->thenError(CategoryNotFound)
  )

  // scenario-id: 4115f220-9d7e-4b6a-bfd1-cc18a5c9916b
  test("Rename on active category produces Renamed", () =>
    givenEvents([Added({name: electronics})])
    ->whenCmd(Rename({name: "Consumer Electronics"}))
    ->thenEvent(Renamed({name: "Consumer Electronics"}))
  )

  // scenario-id: c703e462-c659-496d-a910-6d4507ac351e
  test("Rename to same name produces no events (idempotent)", () =>
    givenEvents([Added({name: electronics})])
    ->whenCmd(Rename({name: electronics}))
    ->thenNoEvent
  )

  // scenario-id: b164ce1f-5f38-4a36-a5c6-26c5491f3735
  test("Rename on archived category returns CategoryAlreadyArchived", () =>
    givenEvents([Added({name: electronics}), Archived])
    ->whenCmd(Rename({name: renamedTo}))
    ->thenError(CategoryAlreadyArchived)
  )

  // scenario-id: a251a06c-44d3-403f-b5ed-664a94e78376
  test("Archive on active category produces Archived", () =>
    givenEvents([Added({name: electronics})])
    ->whenCmd(Archive)
    ->thenEvent(Archived)
  )

  // scenario-id: 4be3d8db-9f51-4967-8ac1-7862ab1a2436
  test("Archive on archived category produces no events (idempotent)", () =>
    givenEvents([Added({name: electronics}), Archived])
    ->whenCmd(Archive)
    ->thenNoEvent
  )
})
