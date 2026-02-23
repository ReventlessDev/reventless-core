// Unit tests for CatalogItem projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

module T = Reventless.ProjectionTest.Make(CatalogItemProjection.ItemMapping)
open T

describe("CatalogItemProjection:", () => {
  test("ItemCreated sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(
      CatalogItemSpec.ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"}),
    )
    ->thenState({
      CatalogItemReadModelSpec.itemId: "item-1",
      name: "Widget",
      description: "A widget",
      archived: false,
    })
  )

  test("ItemUpdated after creation updates name and description", () =>
    givenEvents([
      CatalogItemSpec.ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"}),
    ])
    ->whenEvent(
      CatalogItemSpec.ItemUpdated({
        itemId: "item-1",
        name: "Super Widget",
        description: "An improved widget",
      }),
    )
    ->thenState({
      CatalogItemReadModelSpec.itemId: "item-1",
      name: "Super Widget",
      description: "An improved widget",
      archived: false,
    })
  )

  test("ItemArchived after creation sets archived flag", () =>
    givenEvents([
      CatalogItemSpec.ItemCreated({itemId: "item-1", name: "Widget", description: "A widget"}),
    ])
    ->whenEvent(CatalogItemSpec.ItemArchived({itemId: "item-1"}))
    ->thenState({
      CatalogItemReadModelSpec.itemId: "item-1",
      name: "Widget",
      description: "A widget",
      archived: true,
    })
  )
})
