// Phase 2 validation: Plugin_Structure.make populates all graph fields correctly.
// Uses simplified test specs (PsPlaceOrder, PsShipOrder, PsOrdersView, PsAvailableProductsView)
// and calls Plugin_Structure.make directly — no Platform needed.

open Jest
open Expect

// Stub T modules — Plugin_Structure.make only reads `Spec` fields; `make` is never called.
type scsComponent = Component.t<
  ReventlessInfra.StateChangeSlice.t,
  ReventlessInfra.StateChangeSlice.outputs,
  ReventlessInfra.StateChangeSlice.operations,
>
type svsComponent = Component.t<
  ReventlessInfra.StateViewSlice.t,
  ReventlessInfra.StateViewSlice.outputs,
  ReventlessInfra.StateViewSlice.operations,
>

module PsPlaceOrderSlice: ReventlessInfra.StateChangeSlice.T = {
  module Spec = PsPlaceOrder
  module Behavior = {
    type state = PsPlaceOrder.state
    let initialState = PsPlaceOrder.initialState
    let evolve = PsPlaceOrder.evolve
    let decide = PsPlaceOrder.decide
    let moduleUrl = PsPlaceOrder.moduleUrl
  }
  let isAsync = false
  type component = scsComponent
  let make = (~dcbEventLog as _, ~publishJsons as _, ~opts as _=?): component => Obj.magic(0)
}
module PsShipOrderSlice: ReventlessInfra.StateChangeSlice.T = {
  module Spec = PsShipOrder
  module Behavior = {
    type state = PsShipOrder.state
    let initialState = PsShipOrder.initialState
    let evolve = PsShipOrder.evolve
    let decide = PsShipOrder.decide
    let moduleUrl = PsShipOrder.moduleUrl
  }
  let isAsync = false
  type component = scsComponent
  let make = (~dcbEventLog as _, ~publishJsons as _, ~opts as _=?): component => Obj.magic(0)
}
module PsOrdersViewSlice: ReventlessInfra.StateViewSlice.T = {
  module Spec = PsOrdersView
  module Projection = {
    let project = PsOrdersView.project
    let moduleUrl = PsOrdersView.moduleUrl
  }
  type component = svsComponent
  let make = (~dcbEventLog as _, ~opts as _=?): component => Obj.magic(0)
}
module PsAvailableProductsViewSlice: ReventlessInfra.StateViewSlice.T = {
  module Spec = PsAvailableProductsView
  module Projection = {
    let project = PsAvailableProductsView.project
    let moduleUrl = PsAvailableProductsView.moduleUrl
  }
  type component = svsComponent
  let make = (~dcbEventLog as _, ~opts as _=?): component => Obj.magic(0)
}
module PsCustomersViewSlice: ReventlessInfra.StateViewSlice.T = {
  module Spec = PsCustomersView
  module Projection = {
    let project = PsCustomersView.project
    let moduleUrl = PsCustomersView.moduleUrl
  }
  type component = svsComponent
  let make = (~dcbEventLog as _, ~opts as _=?): component => Obj.magic(0)
}
module PsAnnotatedViewSlice: ReventlessInfra.StateViewSlice.T = {
  module Spec = PsAnnotatedView
  module Projection = {
    let project = PsAnnotatedView.project
    let moduleUrl = PsAnnotatedView.moduleUrl
  }
  type component = svsComponent
  let make = (~dcbEventLog as _, ~opts as _=?): component => Obj.magic(0)
}

let structure = Plugin_Structure.make(
  ~name="TestPlugin",
  ~stateChangeSlices=[module(PsPlaceOrderSlice), module(PsShipOrderSlice)],
  ~stateViewSlices=[
    module(PsOrdersViewSlice),
    module(PsAvailableProductsViewSlice),
    module(PsCustomersViewSlice),
    module(PsAnnotatedViewSlice),
  ],
)

describe("Plugin_Structure.make — Phase 2 graph fields", () => {
  describe("stateChangeSlices", () => {
    test("produces two SCS entries in declaration order", () => {
      expect(structure.stateChangeSlices->Array.length)->toBe(2)
    })

    test("PlaceOrder: producedEventTypes contains OrderPlaced (qualified)", () => {
      let placeOrder = structure.stateChangeSlices->Array.getUnsafe(0)
      expect(placeOrder.producedEventTypes)->toEqual(["TestPlugin.OrderPlaced"])
    })

    test("PlaceOrder: consumedEventTypes contains CatalogProductSynced qualified (payload-less variants excluded)", () => {
      let placeOrder = structure.stateChangeSlices->Array.getUnsafe(0)
      expect(placeOrder.consumedEventTypes)->toEqual(["TestPlugin.CatalogProductSynced"])
    })

    test("PlaceOrder: linkedViews contains Orders (consumes its OrderPlaced)", () => {
      let placeOrder = structure.stateChangeSlices->Array.getUnsafe(0)
      expect(placeOrder.linkedViews)->toEqual(["Orders"])
    })

    test("PlaceOrder: consistencyRead is AvailableProducts (only SVS consuming CatalogProductSynced)", () => {
      let placeOrder = structure.stateChangeSlices->Array.getUnsafe(0)
      expect(placeOrder.consistencyRead)->toEqual(Some("AvailableProducts"))
    })

    test("PlaceOrder command: level Collection (creation command), aggregateIdField orderId for UUID injection", () => {
      let placeOrder = structure.stateChangeSlices->Array.getUnsafe(0)
      let cmd = placeOrder.commands->Array.getUnsafe(0)
      expect((cmd.level, cmd.aggregateIdField))->toEqual((
        Reventless.Plugin.Collection,
        Some("orderId"),
      ))
    })

    test("ShipOrder: producedEventTypes contains OrderShipped (qualified)", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.producedEventTypes)->toEqual(["TestPlugin.OrderShipped"])
    })

    test("ShipOrder: consumedEventTypes is empty (all consumed events are payload-less literals)", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.consumedEventTypes)->toEqual([])
    })

    test("ShipOrder: linkedViews contains Orders (consumes its OrderShipped)", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.linkedViews)->toEqual(["Orders"])
    })

    test("ShipOrder: consistencyRead is None (empty consumedEventTypes cannot overlap any SVS)", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.consistencyRead)->toEqual(None)
    })

    test("ShipOrder command: level Instance, aggregateIdField orderId", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      let cmd = shipOrder.commands->Array.getUnsafe(0)
      expect((cmd.level, cmd.aggregateIdField))->toEqual((
        Reventless.Plugin.Instance,
        Some("orderId"),
      ))
    })
  })

  describe("stateViewSlices", () => {
    test("produces four SVS entries in declaration order", () => {
      expect(structure.stateViewSlices->Array.length)->toBe(4)
    })

    test("OrdersView: consumedEventTypes contains the three order events (qualified)", () => {
      let ordersView = structure.stateViewSlices->Array.getUnsafe(0)
      expect(ordersView.consumedEventTypes)->toEqual([
        "TestPlugin.OrderPlaced",
        "TestPlugin.OrderShipped",
        "TestPlugin.OrderCancelled",
      ])
    })

    test("OrdersView: linkedWriteSide contains both SCS producing order events", () => {
      let ordersView = structure.stateViewSlices->Array.getUnsafe(0)
      expect(ordersView.linkedWriteSide)->toEqual(["PlaceOrder", "ShipOrder"])
    })

    test("AvailableProductsView: consumedEventTypes contains catalog events (qualified)", () => {
      let apv = structure.stateViewSlices->Array.getUnsafe(1)
      expect(apv.consumedEventTypes)->toEqual([
        "TestPlugin.CatalogProductSynced",
        "TestPlugin.CatalogProductPriceChanged",
      ])
    })

    test("AvailableProductsView: linkedWriteSide is empty (no SCS produces these events)", () => {
      let apv = structure.stateViewSlices->Array.getUnsafe(1)
      expect(apv.linkedWriteSide)->toEqual([])
    })
  })

  describe("labelField / searchableFields", () => {
    test("OrdersView: no @displayName → first non-id string field wins (orderId)", () => {
      let ordersView = structure.stateViewSlices->Array.getUnsafe(0)
      expect((ordersView.labelField, ordersView.searchableFields))->toEqual((
        "orderId",
        ["orderId"],
      ))
    })

    test("AvailableProductsView: no @displayName → first non-id string field wins (productId)", () => {
      let apv = structure.stateViewSlices->Array.getUnsafe(1)
      expect((apv.labelField, apv.searchableFields))->toEqual(("productId", ["productId"]))
    })

    test("Customers: composite @displayName → labelField=displayName, searchableFields=raw source fields in declaration order", () => {
      let customers = structure.stateViewSlices->Array.getUnsafe(2)
      expect((customers.labelField, customers.searchableFields))->toEqual((
        "displayName",
        ["firstName", "lastName"],
      ))
    })
  })

  // Phase 4: queryableDef.schema must carry x-reventless-* extension keys for
  // annotated state types. Plugin_Structure now uses SuryToJsonSchema.deriveObjectSchema
  // (annotation-aware) instead of S.toJSONSchema (metadata-blind).
  describe("queryableDef.schema propagates x-reventless-* annotations", () => {
    let getProperty = (json: JSON.t, key: string): option<JSON.t> =>
      switch json->JSON.Decode.object {
      | Some(obj) => obj->Dict.get(key)
      | None => None
      }

    let getPropertyOf = (json: JSON.t, fieldName: string): option<JSON.t> =>
      switch getProperty(json, "properties") {
      | Some(props) =>
        switch props->JSON.Decode.object {
        | Some(obj) => obj->Dict.get(fieldName)
        | None => None
        }
      | None => None
      }

    let parseSchema = (svs: Reventless.Plugin.queryableDef): JSON.t =>
      svs.schema->JSON.parseOrThrow

    let annotatedSchema = structure.stateViewSlices->Array.getUnsafe(3)->parseSchema

    test("itemId carries x-reventless-id", () => {
      expect(
        annotatedSchema
        ->getPropertyOf("itemId")
        ->Option.flatMap(s => getProperty(s, "x-reventless-id"))
        ->Option.flatMap(JSON.Decode.bool),
      )->toBe(Some(true))
    })

    test("version carries x-reventless-subId", () => {
      expect(
        annotatedSchema
        ->getPropertyOf("version")
        ->Option.flatMap(s => getProperty(s, "x-reventless-subId"))
        ->Option.flatMap(JSON.Decode.bool),
      )->toBe(Some(true))
    })

    test("ownerId carries x-reventless-index = byOwner", () => {
      expect(
        annotatedSchema
        ->getPropertyOf("ownerId")
        ->Option.flatMap(s => getProperty(s, "x-reventless-index"))
        ->Option.flatMap(JSON.Decode.string),
      )->toBe(Some("byOwner"))
    })

    test("unannotated field 'name' has no x-reventless-* keys", () => {
      let nameField = annotatedSchema->getPropertyOf("name")
      expect((
        nameField->Option.flatMap(s => getProperty(s, "x-reventless-id")),
        nameField->Option.flatMap(s => getProperty(s, "x-reventless-subId")),
        nameField->Option.flatMap(s => getProperty(s, "x-reventless-index")),
      ))->toEqual((None, None, None))
    })

    test("unannotated state-view slice (Orders) emits no x-reventless-* keys", () => {
      let ordersSchema = structure.stateViewSlices->Array.getUnsafe(0)->parseSchema
      let orderIdField = ordersSchema->getPropertyOf("orderId")
      expect(
        orderIdField->Option.flatMap(s => getProperty(s, "x-reventless-id")),
      )->toBe(None)
    })
  })
})
