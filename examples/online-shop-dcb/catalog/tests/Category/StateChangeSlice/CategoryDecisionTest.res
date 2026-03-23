// Pure unit tests for Category StateChangeSlice decision logic.
// Tests evolve and decide functions for AddCategory, RenameCategory, and ArchiveCategory.

open Jest
open Expect

describe("AddCategory:", () => {
  describe("evolve", () => {
    test("CategoryAdded sets exists=true", () =>
      expect(
        AddCategory.evolve(
          AddCategory.initialState,
          CatalogEventLog.CategoryAdded({categoryId: "c1", name: "Electronics"}),
        ),
      )->toEqual({AddCategory.exists: true, archived: false})
    )

    test("CategoryArchived sets archived=true", () =>
      expect(
        AddCategory.evolve(
          {AddCategory.exists: true, archived: false},
          CatalogEventLog.CategoryArchived({categoryId: "c1"}),
        ),
      )->toEqual({AddCategory.exists: true, archived: true})
    )

    test("Product events do not change state", () =>
      expect(
        AddCategory.evolve(
          AddCategory.initialState,
          CatalogEventLog.ProductAdded({
            productId: "p1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ),
      )->toEqual(AddCategory.initialState)
    )
  })

  describe("decide", () => {
    test("on non-existent category produces CategoryAdded", () =>
      expect(
        AddCategory.decide(
          AddCategory.initialState,
          AddCategory.AddCategory({categoryId: "c1", name: "Electronics"}),
        ),
      )->toEqual(Ok([CatalogEventLog.CategoryAdded({categoryId: "c1", name: "Electronics"})]))
    )

    test("on existing category returns CategoryAlreadyExists", () =>
      expect(
        AddCategory.decide(
          {AddCategory.exists: true, archived: false},
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
        RenameCategory.decide(
          RenameCategory.initialState,
          RenameCategory.RenameCategory({categoryId: "c1", name: "Consumer Electronics"}),
        ),
      )->toEqual(Error(RenameCategory.CategoryNotFound))
    )

    test("on archived category returns CategoryAlreadyArchived", () =>
      expect(
        RenameCategory.decide(
          {RenameCategory.exists: true, archived: true},
          RenameCategory.RenameCategory({categoryId: "c1", name: "Consumer Electronics"}),
        ),
      )->toEqual(Error(RenameCategory.CategoryAlreadyArchived))
    )

    test("on active category produces CategoryRenamed", () =>
      expect(
        RenameCategory.decide(
          {RenameCategory.exists: true, archived: false},
          RenameCategory.RenameCategory({categoryId: "c1", name: "Consumer Electronics"}),
        ),
      )->toEqual(
        Ok([CatalogEventLog.CategoryRenamed({categoryId: "c1", name: "Consumer Electronics"})]),
      )
    )
  })
})

describe("ArchiveCategory:", () => {
  describe("decide", () => {
    test("on non-existent category returns CategoryNotFound", () =>
      expect(
        ArchiveCategory.decide(
          ArchiveCategory.initialState,
          ArchiveCategory.ArchiveCategory({categoryId: "c1"}),
        ),
      )->toEqual(Error(ArchiveCategory.CategoryNotFound))
    )

    test("on already archived category returns Ok([]) (idempotent)", () =>
      expect(
        ArchiveCategory.decide(
          {ArchiveCategory.exists: true, archived: true},
          ArchiveCategory.ArchiveCategory({categoryId: "c1"}),
        ),
      )->toEqual(Ok([]))
    )

    test("on active category produces CategoryArchived", () =>
      expect(
        ArchiveCategory.decide(
          {ArchiveCategory.exists: true, archived: false},
          ArchiveCategory.ArchiveCategory({categoryId: "c1"}),
        ),
      )->toEqual(Ok([CatalogEventLog.CategoryArchived({categoryId: "c1"})]))
    )
  })
})
