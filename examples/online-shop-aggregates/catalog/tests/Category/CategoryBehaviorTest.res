// Unit tests for Category aggregate behavior.
// Uses the BehaviorTest DSL for pure synchronous testing.

open Category

include ReventlessGwt.Behavior_GWT.MakeFromAggregate(Category, CategoryBehavior)

describe("CategoryBehavior:", () => {
  describe("Add", () => {
    test(
      "on new aggregate produces Added",
      () =>
        givenEvents([])
        ->whenCmd(Add({name: "Electronics"}))
        ->thenEvent(Added({name: "Electronics"})),
    )

    test(
      "on existing aggregate returns CategoryAlreadyExists error",
      () =>
        givenEvents([Added({name: "Electronics"})])
        ->whenCmd(Add({name: "Electronics 2"}))
        ->thenError(CategoryAlreadyExists),
    )
  })

  describe("Rename", () => {
    test(
      "on non-existent aggregate returns CategoryNotFound error",
      () =>
        givenEvents([])
        ->whenCmd(Rename({name: "New Name"}))
        ->thenError(CategoryNotFound),
    )

    test(
      "on active category produces Renamed",
      () =>
        givenEvents([Added({name: "Electronics"})])
        ->whenCmd(Rename({name: "Consumer Electronics"}))
        ->thenEvent(Renamed({name: "Consumer Electronics"})),
    )

    test(
      "on archived category returns CategoryAlreadyArchived error",
      () =>
        givenEvents([
          Added({name: "Electronics"}),
          Archived,
        ])
        ->whenCmd(Rename({name: "New Name"}))
        ->thenError(CategoryAlreadyArchived),
    )
  })

  describe("Archive", () => {
    test(
      "on active category produces Archived",
      () =>
        givenEvents([Added({name: "Electronics"})])
        ->whenCmd(Archive)
        ->thenEvent(Archived),
    )

    test(
      "on archived category is idempotent (produces no events)",
      () =>
        givenEvents([
          Added({name: "Electronics"}),
          Archived,
        ])
        ->whenCmd(Archive)
        ->thenNoEvent,
    )
  })
})
