// Unit tests for CatalogItem projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

module T = Reventless.ProjectionTest.Make(CatalogItemsProjections.ItemMapping)
open T

describe("CatalogItemProjection:", () => {
  test("ItemCreated sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(
      CatalogItem.ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"}),
    )
    ->thenState({
      CatalogItemsReadModel.itemId: "item-1",
      name: "Widget",
      description: "A widget",
      archived: false,
    })
  )

  test("ItemUpdated after creation updates name and description", () =>
    givenEvents([
      CatalogItem.ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"}),
    ])
    ->whenEvent(
      CatalogItem.ItemUpdated({
        itemId: "item-1",
        name: "Super Widget",
        description: "An improved widget",
      }),
    )
    ->thenState({
      CatalogItemsReadModel.itemId: "item-1",
      name: "Super Widget",
      description: "An improved widget",
      archived: false,
    })
  )

  test("ItemRenamed after creation updates name", () =>
    givenEvents([
      CatalogItem.ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"}),
    ])
    ->whenEvent(CatalogItem.ItemRenamed({itemId: "item-1", newName: "Super Widget"}))
    ->thenState({
      CatalogItemsReadModel.itemId: "item-1",
      name: "Super Widget",
      description: "A widget",
      archived: false,
    })
  )

  test("ItemArchived after creation sets archived flag", () =>
    givenEvents([
      CatalogItem.ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"}),
    ])
    ->whenEvent(CatalogItem.ItemArchived({itemId: "item-1"}))
    ->thenState({
      CatalogItemsReadModel.itemId: "item-1",
      name: "Widget",
      description: "A widget",
      archived: true,
    })
  )
})
