// Unit tests for CatalogItem aggregate behavior.
// Uses the BehaviorTest DSL for pure synchronous testing.

open CatalogItem

module T = Reventless.BehaviorTest.Make(CatalogItem, CatalogItemBehavior)
open T

describe("CatalogItemBehavior:", () => {
  describe("CreateItem", () => {
    test(
      "on new aggregate produces ItemCreated",
      () =>
        givenEvents([])
        ->whenCmd(CreateItem({itemId: "item-1", name: "Widget", description: "A widget"}))
        ->thenEvent(ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"})),
    )

    test(
      "on existing aggregate returns ItemAlreadyExists error",
      () =>
        givenEvents([ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"})])
        ->whenCmd(CreateItem({itemId: "item-1", name: "Widget2", description: "Another widget"}))
        ->thenError(ItemAlreadyExists),
    )
  })

  describe("UpdateItem", () => {
    test(
      "on non-existent aggregate returns ItemNotFound error",
      () =>
        givenEvents([])
        ->whenCmd(UpdateItem({itemId: "item-1", name: "Updated", description: "Updated desc"}))
        ->thenError(ItemNotFound),
    )

    test(
      "on active item produces ItemUpdated",
      () =>
        givenEvents([ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"})])
        ->whenCmd(
          UpdateItem({itemId: "item-1", name: "Updated Widget", description: "Updated desc"}),
        )
        ->thenEvent(
          ItemUpdated({itemId: "item-1", name: "Updated Widget", description: "Updated desc"}),
        ),
    )

    test(
      "on archived item returns ItemAlreadyArchived error",
      () =>
        givenEvents([
          ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"}),
          ItemArchived({itemId: "item-1"}),
        ])
        ->whenCmd(UpdateItem({itemId: "item-1", name: "Updated", description: "Updated desc"}))
        ->thenError(ItemAlreadyArchived),
    )
  })

  describe("RenameItem", () => {
    test(
      "on non-existent aggregate returns ItemNotFound error",
      () =>
        givenEvents([])
        ->whenCmd(RenameItem({itemId: "item-1", newName: "New Name"}))
        ->thenError(ItemNotFound),
    )

    test(
      "on active item produces ItemRenamed",
      () =>
        givenEvents([ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"})])
        ->whenCmd(RenameItem({itemId: "item-1", newName: "Super Widget"}))
        ->thenEvent(ItemRenamed({itemId: "item-1", newName: "Super Widget"})),
    )

    test(
      "on archived item returns ItemAlreadyArchived error",
      () =>
        givenEvents([
          ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"}),
          ItemArchived({itemId: "item-1"}),
        ])
        ->whenCmd(RenameItem({itemId: "item-1", newName: "New Name"}))
        ->thenError(ItemAlreadyArchived),
    )
  })

  describe("ArchiveItem", () => {
    test(
      "on active item produces ItemArchived",
      () =>
        givenEvents([ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"})])
        ->whenCmd(ArchiveItem({itemId: "item-1"}))
        ->thenEvent(ItemArchived({itemId: "item-1"})),
    )

    test(
      "on archived item is idempotent (produces no events)",
      () =>
        givenEvents([
          ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"}),
          ItemArchived({itemId: "item-1"}),
        ])
        ->whenCmd(ArchiveItem({itemId: "item-1"}))
        ->thenNoEvent,
    )
  })
})
