open JestGlobals
open Reventless.Projection
open EventMapperFixtures

describe("Mapping.Make:", () => {
  describe("sourceName", () => {
    testSync("equals source spec name", () =>
      expect(ItemMapping.sourceName)->toBe("SourceAggregate")
    )
  })

  describe("project", () => {
    testSync("ItemCreated maps to Create action", () => {
      let event' = makeSourceEvent'("item-1", SourceSpec.ItemCreated({name: "Widget", price: 9.99}))
      let action = ItemMapping.project(event')
      switch action {
      | Create(id, state) =>
        expect((id, state.name, state.price))->toEqual(("item-1", "Widget", 9.99))
      | _ => fail("Expected Create action")
      }
    })

    testSync("ItemPriceUpdated maps to Update action", () => {
      let event' = makeSourceEvent'("item-1", SourceSpec.ItemPriceUpdated({newPrice: 14.99}))
      let action = ItemMapping.project(event')
      switch action {
      | Update(id, _) => expect(id)->toBe("item-1")
      | _ => fail("Expected Update action")
      }
    })

    testSync("ItemRemoved maps to Delete action", () => {
      let event' = makeSourceEvent'("item-1", SourceSpec.ItemRemoved)
      let action = ItemMapping.project(event')
      switch action {
      | Delete(id) => expect(id)->toBe("item-1")
      | _ => fail("Expected Delete action")
      }
    })

    testSync("Update action applies function correctly", () => {
      let event' = makeSourceEvent'("item-1", SourceSpec.ItemPriceUpdated({newPrice: 14.99}))
      let action = ItemMapping.project(event')
      switch action {
      | Update(_, fn) =>
        let originalState: TargetSpec.state = {name: "Widget", price: 9.99}
        let updated = fn(originalState)
        expect(updated.price)->toBe(14.99)
      | _ => fail("Expected Update action")
      }
    })
  })
})
