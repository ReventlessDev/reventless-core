// Pure unit tests for ItemView StateViewSlice projection.
// Tests the project function synchronously with all event types.

open Jest
open Expect

let existingItem: ItemView.state = {itemId: "i1", name: "Widget", archived: false}

describe("ItemView.project:", () => {
  test("ItemCreated on None creates new state", () =>
    expect(
      ItemView.project(None, ItemEventLog.ItemCreated({itemId: "i1", name: "Widget"}))
    )->toEqual([
      ReventlessSpec.Projection.Set("i1", {ItemView.itemId: "i1", name: "Widget", archived: false}),
    ])
  )

  test("ItemRenamed on existing state updates name", () =>
    expect(
      ItemView.project(
        Some(existingItem),
        ItemEventLog.ItemRenamed({itemId: "i1", newName: "Super Widget"}),
      )
    )->toEqual([
      ReventlessSpec.Projection.Set("i1", {ItemView.itemId: "i1", name: "Super Widget", archived: false}),
    ])
  )

  test("ItemRenamed on None returns empty (item not found)", () =>
    expect(
      ItemView.project(None, ItemEventLog.ItemRenamed({itemId: "i1", newName: "Super Widget"}))
    )->toEqual([])
  )

  test("ItemArchived on existing state sets archived=true", () =>
    expect(
      ItemView.project(Some(existingItem), ItemEventLog.ItemArchived({itemId: "i1"}))
    )->toEqual([
      ReventlessSpec.Projection.Set("i1", {ItemView.itemId: "i1", name: "Widget", archived: true}),
    ])
  )

  test("ItemArchived on None returns empty (item not found)", () =>
    expect(
      ItemView.project(None, ItemEventLog.ItemArchived({itemId: "i1"}))
    )->toEqual([])
  )
})
