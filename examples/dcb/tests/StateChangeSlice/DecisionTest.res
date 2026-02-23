// Pure unit tests for StateChangeSlice decision logic.
// Tests the reduce and decide functions of all three StateChangeSlice specs synchronously.

open Jest
open Expect

describe("CreateItem:", () => {
  describe("reduce", () => {
    test("ItemCreated sets exists=true", () =>
      expect(
        CreateItem.reduce(CreateItem.initialDecisionModel, ItemEventLog.ItemCreated({itemId: "i1", name: "Widget"}))
      )->toEqual({CreateItem.exists: true, archived: false})
    )

    test("ItemArchived sets archived=true", () =>
      expect(
        CreateItem.reduce(
          {CreateItem.exists: true, archived: false},
          ItemEventLog.ItemArchived({itemId: "i1"}),
        )
      )->toEqual({CreateItem.exists: true, archived: true})
    )

    test("ItemRenamed does not change model", () =>
      expect(
        CreateItem.reduce(CreateItem.initialDecisionModel, ItemEventLog.ItemRenamed({itemId: "i1", newName: "x"}))
      )->toEqual(CreateItem.initialDecisionModel)
    )
  })

  describe("decide", () => {
    test("on non-existent item creates ItemCreated", () =>
      expect(
        CreateItem.decide(
          CreateItem.initialDecisionModel,
          CreateItem.CreateItem({itemId: "i1", name: "Widget"}),
        )
      )->toEqual(Ok([ItemEventLog.ItemCreated({itemId: "i1", name: "Widget"})]))
    )

    test("on existing item returns ItemAlreadyExists", () =>
      expect(
        CreateItem.decide(
          {CreateItem.exists: true, archived: false},
          CreateItem.CreateItem({itemId: "i1", name: "Widget"}),
        )
      )->toEqual(Error(CreateItem.ItemAlreadyExists))
    )
  })
})

describe("RenameItem:", () => {
  describe("decide", () => {
    test("on non-existent item returns ItemNotFound", () =>
      expect(
        RenameItem.decide(
          RenameItem.initialDecisionModel,
          RenameItem.RenameItem({itemId: "i1", newName: "New Name"}),
        )
      )->toEqual(Error(RenameItem.ItemNotFound))
    )

    test("on archived item returns ItemAlreadyArchived", () =>
      expect(
        RenameItem.decide(
          {RenameItem.exists: true, archived: true},
          RenameItem.RenameItem({itemId: "i1", newName: "New Name"}),
        )
      )->toEqual(Error(RenameItem.ItemAlreadyArchived))
    )

    test("on active item produces ItemRenamed", () =>
      expect(
        RenameItem.decide(
          {RenameItem.exists: true, archived: false},
          RenameItem.RenameItem({itemId: "i1", newName: "Super Widget"}),
        )
      )->toEqual(Ok([ItemEventLog.ItemRenamed({itemId: "i1", newName: "Super Widget"})]))
    )
  })
})

describe("ArchiveItem:", () => {
  describe("decide", () => {
    test("on non-existent item returns ItemNotFound", () =>
      expect(
        ArchiveItem.decide(
          ArchiveItem.initialDecisionModel,
          ArchiveItem.ArchiveItem({itemId: "i1"}),
        )
      )->toEqual(Error(ArchiveItem.ItemNotFound))
    )

    test("on already archived item returns Ok([]) (idempotent)", () =>
      expect(
        ArchiveItem.decide(
          {ArchiveItem.exists: true, archived: true},
          ArchiveItem.ArchiveItem({itemId: "i1"}),
        )
      )->toEqual(Ok([]))
    )

    test("on active item produces ItemArchived", () =>
      expect(
        ArchiveItem.decide(
          {ArchiveItem.exists: true, archived: false},
          ArchiveItem.ArchiveItem({itemId: "i1"}),
        )
      )->toEqual(Ok([ItemEventLog.ItemArchived({itemId: "i1"})]))
    )
  })
})
