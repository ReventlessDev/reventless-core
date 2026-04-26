// Pure unit tests for Category StateChangeSlice decision logic.
// Tests evolve and decide functions for AddCategory, RenameCategory, and ArchiveCategory.

open Jest
open Expect

describe("AddCategory:", () => {
  describe("evolve", () => {
    test("CategoryAdded sets exists=true", () =>
      expect(
        AddCategory_Behavior.evolve(
          AddCategory_Behavior.initialState,
          AddCategory.CategoryAdded,
        ),
      )->toEqual({AddCategory_Behavior.exists: true, archived: false})
    )

    test("CategoryArchived sets archived=true", () =>
      expect(
        AddCategory_Behavior.evolve(
          {AddCategory_Behavior.exists: true, archived: false},
          AddCategory.CategoryArchived,
        ),
      )->toEqual({AddCategory_Behavior.exists: true, archived: true})
    )

})

  describe("decide", () => {
    test("on non-existent category produces CategoryAdded", () =>
      expect(
        AddCategory_Behavior.decide(
          AddCategory_Behavior.initialState,
          AddCategory.AddCategory({categoryId: "c1", name: "Electronics"}),
        ),
      )->toEqual(Ok([AddCategory.CategoryAdded({categoryId: "c1", name: "Electronics"})]))
    )

    test("on existing category returns CategoryAlreadyExists", () =>
      expect(
        AddCategory_Behavior.decide(
          {AddCategory_Behavior.exists: true, archived: false},
          AddCategory.AddCategory({categoryId: "c1", name: "Electronics"}),
        ),
      )->toEqual(Error(AddCategory.CategoryAlreadyExists))
    )
  })
})

describe("RenameCategory:", () => {
  describe("decide", () => {
    test("on non-existent category returns CategoryNotFound", () =>
      expect(
        RenameCategory_Behavior.decide(
          RenameCategory_Behavior.initialState,
          RenameCategory.RenameCategory({categoryId: "c1", name: "Consumer Electronics"}),
        ),
      )->toEqual(Error(RenameCategory.CategoryNotFound))
    )

    test("on archived category returns CategoryAlreadyArchived", () =>
      expect(
        RenameCategory_Behavior.decide(
          {RenameCategory_Behavior.exists: true, archived: true},
          RenameCategory.RenameCategory({categoryId: "c1", name: "Consumer Electronics"}),
        ),
      )->toEqual(Error(RenameCategory.CategoryAlreadyArchived))
    )

    test("on active category produces CategoryRenamed", () =>
      expect(
        RenameCategory_Behavior.decide(
          {RenameCategory_Behavior.exists: true, archived: false},
          RenameCategory.RenameCategory({categoryId: "c1", name: "Consumer Electronics"}),
        ),
      )->toEqual(
        Ok([RenameCategory.CategoryRenamed({categoryId: "c1", name: "Consumer Electronics"})]),
      )
    )
  })
})

describe("ArchiveCategory:", () => {
  describe("decide", () => {
    test("on non-existent category returns CategoryNotFound", () =>
      expect(
        ArchiveCategory_Behavior.decide(
          ArchiveCategory_Behavior.initialState,
          ArchiveCategory.ArchiveCategory({categoryId: "c1"}),
        ),
      )->toEqual(Error(ArchiveCategory.CategoryNotFound))
    )

    test("on already archived category returns Ok([]) (idempotent)", () =>
      expect(
        ArchiveCategory_Behavior.decide(
          {ArchiveCategory_Behavior.exists: true, archived: true},
          ArchiveCategory.ArchiveCategory({categoryId: "c1"}),
        ),
      )->toEqual(Ok([]))
    )

    test("on active category produces CategoryArchived", () =>
      expect(
        ArchiveCategory_Behavior.decide(
          {ArchiveCategory_Behavior.exists: true, archived: false},
          ArchiveCategory.ArchiveCategory({categoryId: "c1"}),
        ),
      )->toEqual(Ok([ArchiveCategory.CategoryArchived({categoryId: "c1"})]))
    )
  })
})
