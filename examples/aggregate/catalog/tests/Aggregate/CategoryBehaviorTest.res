// Unit tests for Category aggregate behavior.
// Uses the BehaviorTest DSL for pure synchronous testing.

open Category

include Reventless.BehaviorTest.Make(Category, CategoryBehavior)

describe("CategoryBehavior:", () => {
  describe("AddCategory", () => {
    test(
      "on new aggregate produces CategoryAdded",
      () =>
        givenEvents([])
        ->whenCmd(AddCategory({categoryId: "cat-1", name: "Electronics"}))
        ->thenEvent(CategoryAdded({categoryId: "cat-1", name: "Electronics"})),
    )

    test(
      "on existing aggregate returns CategoryAlreadyExists error",
      () =>
        givenEvents([CategoryAdded({categoryId: "cat-1", name: "Electronics"})])
        ->whenCmd(AddCategory({categoryId: "cat-1", name: "Electronics 2"}))
        ->thenError(CategoryAlreadyExists),
    )
  })

  describe("RenameCategory", () => {
    test(
      "on non-existent aggregate returns CategoryNotFound error",
      () =>
        givenEvents([])
        ->whenCmd(RenameCategory({categoryId: "cat-1", name: "New Name"}))
        ->thenError(CategoryNotFound),
    )

    test(
      "on active category produces CategoryRenamed",
      () =>
        givenEvents([CategoryAdded({categoryId: "cat-1", name: "Electronics"})])
        ->whenCmd(RenameCategory({categoryId: "cat-1", name: "Consumer Electronics"}))
        ->thenEvent(CategoryRenamed({categoryId: "cat-1", name: "Consumer Electronics"})),
    )

    test(
      "on archived category returns CategoryAlreadyArchived error",
      () =>
        givenEvents([
          CategoryAdded({categoryId: "cat-1", name: "Electronics"}),
          CategoryArchived({categoryId: "cat-1"}),
        ])
        ->whenCmd(RenameCategory({categoryId: "cat-1", name: "New Name"}))
        ->thenError(CategoryAlreadyArchived),
    )
  })

  describe("ArchiveCategory", () => {
    test(
      "on active category produces CategoryArchived",
      () =>
        givenEvents([CategoryAdded({categoryId: "cat-1", name: "Electronics"})])
        ->whenCmd(ArchiveCategory({categoryId: "cat-1"}))
        ->thenEvent(CategoryArchived({categoryId: "cat-1"})),
    )

    test(
      "on archived category is idempotent (produces no events)",
      () =>
        givenEvents([
          CategoryAdded({categoryId: "cat-1", name: "Electronics"}),
          CategoryArchived({categoryId: "cat-1"}),
        ])
        ->whenCmd(ArchiveCategory({categoryId: "cat-1"}))
        ->thenNoEvent,
    )
  })
})
