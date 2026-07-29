// Phase 2 validation: Plugin_Structure.make populates all graph fields correctly.
// Uses simplified test specs (PsPlaceOrder, PsShipOrder, PsOrdersView, PsAvailableProductsView)
// and calls Plugin_Structure.make directly — no Platform needed.

open JestGlobals

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
  let make = (~dcbEventLog as _, ~publishJsons as _, ~tagKeysByEventType as _=?, ~crossPartitionTagKeys as _=?, ~runtime as _=?, ~opts as _=?): component => Obj.magic(0)
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
  let make = (~dcbEventLog as _, ~publishJsons as _, ~tagKeysByEventType as _=?, ~crossPartitionTagKeys as _=?, ~runtime as _=?, ~opts as _=?): component => Obj.magic(0)
}
module PsOrdersViewSlice: ReventlessInfra.StateViewSlice.T = {
  module Spec = PsOrdersView
  module Projection = {
    let project = PsOrdersView.project
    let moduleUrl = PsOrdersView.moduleUrl
  }
  type component = svsComponent
  let make = (~dcbEventLog as _, ~runtime as _=?, ~opts as _=?): component => Obj.magic(0)
}
module PsAvailableProductsViewSlice: ReventlessInfra.StateViewSlice.T = {
  module Spec = PsAvailableProductsView
  module Projection = {
    let project = PsAvailableProductsView.project
    let moduleUrl = PsAvailableProductsView.moduleUrl
  }
  type component = svsComponent
  let make = (~dcbEventLog as _, ~runtime as _=?, ~opts as _=?): component => Obj.magic(0)
}
module PsCustomersViewSlice: ReventlessInfra.StateViewSlice.T = {
  module Spec = PsCustomersView
  module Projection = {
    let project = PsCustomersView.project
    let moduleUrl = PsCustomersView.moduleUrl
  }
  type component = svsComponent
  let make = (~dcbEventLog as _, ~runtime as _=?, ~opts as _=?): component => Obj.magic(0)
}
module PsAnnotatedViewSlice: ReventlessInfra.StateViewSlice.T = {
  module Spec = PsAnnotatedView
  module Projection = {
    let project = PsAnnotatedView.project
    let moduleUrl = PsAnnotatedView.moduleUrl
  }
  type component = svsComponent
  let make = (~dcbEventLog as _, ~runtime as _=?, ~opts as _=?): component => Obj.magic(0)
}

module PsAttachInvoiceSlice: ReventlessInfra.StateChangeSlice.T = {
  module Spec = PsAttachInvoice
  module Behavior = {
    type state = PsAttachInvoice.state
    let initialState = PsAttachInvoice.initialState
    let evolve = PsAttachInvoice.evolve
    let decide = PsAttachInvoice.decide
    let moduleUrl = PsAttachInvoice.moduleUrl
  }
  let isAsync = false
  type component = scsComponent
  let make = (~dcbEventLog as _, ~publishJsons as _, ~tagKeysByEventType as _=?, ~crossPartitionTagKeys as _=?, ~runtime as _=?, ~opts as _=?): component => Obj.magic(0)
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
    testSync("produces two SCS entries in declaration order", () => {
      expect(structure.stateChangeSlices->Array.length)->toBe(2)
    })

    testSync("PlaceOrder: producedEventTypes contains OrderPlaced (qualified)", () => {
      let placeOrder = structure.stateChangeSlices->Array.getUnsafe(0)
      expect(placeOrder.producedEventTypes)->toEqual(["TestPlugin.OrderPlaced"])
    })

    testSync("PlaceOrder: consumedEventTypes contains CatalogProductSynced qualified (payload-less variants excluded)", () => {
      let placeOrder = structure.stateChangeSlices->Array.getUnsafe(0)
      expect(placeOrder.consumedEventTypes)->toEqual(["TestPlugin.CatalogProductSynced"])
    })

    testSync("PlaceOrder: linkedViews contains Orders (consumes its OrderPlaced)", () => {
      let placeOrder = structure.stateChangeSlices->Array.getUnsafe(0)
      expect(placeOrder.linkedViews)->toEqual(["Orders"])
    })

    testSync("PlaceOrder: consistencyRead is AvailableProducts (only SVS consuming CatalogProductSynced)", () => {
      let placeOrder = structure.stateChangeSlices->Array.getUnsafe(0)
      expect(placeOrder.consistencyRead)->toEqual(Some("AvailableProducts"))
    })

    testSync("PlaceOrder command: level Collection (creation command), aggregateIdField orderId for UUID injection", () => {
      let placeOrder = structure.stateChangeSlices->Array.getUnsafe(0)
      let cmd = placeOrder.commands->Array.getUnsafe(0)
      expect((cmd.level, cmd.aggregateIdField))->toEqual((
        Reventless.Plugin.Collection,
        Some("orderId"),
      ))
    })

    testSync("ShipOrder: producedEventTypes contains OrderShipped (qualified)", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.producedEventTypes)->toEqual(["TestPlugin.OrderShipped"])
    })

    testSync("ShipOrder: consumedEventTypes is empty (all consumed events are payload-less literals)", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.consumedEventTypes)->toEqual([])
    })

    testSync("ShipOrder: linkedViews contains Orders (consumes its OrderShipped)", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.linkedViews)->toEqual(["Orders"])
    })

    testSync("ShipOrder: consistencyRead is None (empty consumedEventTypes cannot overlap any SVS)", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.consistencyRead)->toEqual(None)
    })

    testSync("ShipOrder command: level Instance, aggregateIdField orderId", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      let cmd = shipOrder.commands->Array.getUnsafe(0)
      expect((cmd.level, cmd.aggregateIdField))->toEqual((
        Reventless.Plugin.Instance,
        Some("orderId"),
      ))
    })

    testSync("ShipOrder: payload-less command CancelShipment is surfaced in commands", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.commands->Array.map(c => c.name))->toEqual(["ShipOrder", "CancelShipment"])
    })

    testSync("ShipOrder: the @noApi CancelShipment is tagged apiExposed=false; ShipOrder stays exposed", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      let byName = name => shipOrder.commands->Array.find(c => c.name == name)
      expect((
        byName("ShipOrder")->Option.flatMap(c => c.apiExposed),
        byName("CancelShipment")->Option.flatMap(c => c.apiExposed),
      ))->toEqual((Some(true), Some(false)))
    })

    testSync("ShipOrder: @targetState(\"Shipped\") flows through the PPX to commandDef.targetState", () => {
      // End-to-end: the reventless-ppx @targetState annotation → markTargetState
      // metadata → ApiTargetStateHelpers.getTargetState → commandDef. The
      // un-annotated CancelShipment carries None (resolver falls back to
      // name-stem).
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      let byName = name => shipOrder.commands->Array.find(c => c.name == name)
      expect((
        byName("ShipOrder")->Option.flatMap(c => c.targetState),
        byName("CancelShipment")->Option.flatMap(c => c.targetState),
      ))->toEqual((Some("Shipped"), None))
    })

    testSync("ShipOrder: the @noApi variant carries no callable mutation field (no sibling leak)", () => {
      // Regression: for a single-exposed-command slice, `mutationFieldFor`
      // resolves every variant — including the @noApi one — to the slice's one
      // mutation field. The non-exposed variant must not carry that sibling
      // field; it emits an empty sentinel instead, while the exposed command
      // keeps a real, non-empty field.
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      let byName = name => shipOrder.commands->Array.find(c => c.name == name)
      let shipField = byName("ShipOrder")->Option.map(c => c.mutationField)->Option.getOr("")
      let cancelField = byName("CancelShipment")->Option.map(c => c.mutationField)->Option.getOr("x")
      expect((shipField->String.length > 0, cancelField))->toEqual((true, ""))
    })

    testSync("ShipOrder: payload-less event ShipmentVoided is surfaced in events", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.events->Array.map(e => e.name))->toEqual(["OrderShipped", "ShipmentVoided"])
    })

    testSync("ShipOrder: producedEventTypes still excludes the payload-less ShipmentVoided (DCB filter intact)", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.producedEventTypes)->toEqual(["TestPlugin.OrderShipped"])
    })
  })

  describe("stateViewSlices", () => {
    testSync("produces four SVS entries in declaration order", () => {
      expect(structure.stateViewSlices->Array.length)->toBe(4)
    })

    testSync("OrdersView: consumedEventTypes contains the three order events (qualified)", () => {
      let ordersView = structure.stateViewSlices->Array.getUnsafe(0)
      expect(ordersView.consumedEventTypes)->toEqual([
        "TestPlugin.OrderPlaced",
        "TestPlugin.OrderShipped",
        "TestPlugin.OrderCancelled",
      ])
    })

    testSync("OrdersView: linkedWriteSide contains both SCS producing order events", () => {
      let ordersView = structure.stateViewSlices->Array.getUnsafe(0)
      expect(ordersView.linkedWriteSide)->toEqual(["PlaceOrder", "ShipOrder"])
    })

    testSync("AvailableProductsView: consumedEventTypes contains catalog events (qualified)", () => {
      let apv = structure.stateViewSlices->Array.getUnsafe(1)
      expect(apv.consumedEventTypes)->toEqual([
        "TestPlugin.CatalogProductSynced",
        "TestPlugin.CatalogProductPriceChanged",
      ])
    })

    testSync("AvailableProductsView: linkedWriteSide is empty (no SCS produces these events)", () => {
      let apv = structure.stateViewSlices->Array.getUnsafe(1)
      expect(apv.linkedWriteSide)->toEqual([])
    })
  })

  describe("labelField / searchableFields", () => {
    testSync("OrdersView: no @displayName → first non-`*Id` string field wins (customerName)", () => {
      let ordersView = structure.stateViewSlices->Array.getUnsafe(0)
      expect((ordersView.labelField, ordersView.searchableFields))->toEqual((
        "customerName",
        ["customerName"],
      ))
    })

    testSync("AvailableProductsView: no @displayName → first non-`*Id` string field wins (name)", () => {
      let apv = structure.stateViewSlices->Array.getUnsafe(1)
      expect((apv.labelField, apv.searchableFields))->toEqual(("name", ["name"]))
    })

    testSync("Customers: composite @displayName → labelField=displayName, searchableFields=raw source fields in declaration order", () => {
      let customers = structure.stateViewSlices->Array.getUnsafe(2)
      expect((customers.labelField, customers.searchableFields))->toEqual((
        "displayName",
        ["firstName", "lastName"],
      ))
    })
  })

  // What a field *is* comes from `SchemaType`, the IR every other schema
  // consumer reads, rather than from a `String(_)` match here. These pin the
  // shapes that separates the two: a date, a reference, a semantic-carrying
  // string and an optional one all match `String(_)` loosely or not at all, and
  // each was answered wrong before.
  describe("labelField — the shape rule", () => {
    let labelOf = (~entityName="Test", schema) => {
      let r = Plugin_Structure.labelFieldsFromStateSchema(~entityName, schema->S.castToUnknown)
      (r.field, r.searchableFields)
    }

    testSync("a DateTime is not a name — a state whose only string is one falls to id", () => {
      // The shipped `Orders` case: `placedAt` was added so date views have a
      // field to key off, and a positional rule let it rename the entity.
      let schema = S.schema(s =>
        {
          "orderId": s.matches(Reventless.Reference.to_("Order")),
          "placedAt": s.matches(Reventless.DateTime.string),
          "shippedAt": s.matches(Reventless.DateTime.string),
        }
      )
      expect(labelOf(schema))->toEqual(("id", []))
    })

    testSync("a DateTime is skipped, not fatal — a later plain string still wins", () => {
      let schema = S.schema(s =>
        {
          "placedAt": s.matches(Reventless.DateTime.string),
          "reference": s.matches(S.string),
        }
      )
      expect(labelOf(schema))->toEqual(("reference", ["reference"]))
    })

    testSync("an optional string is still the entity's name", () => {
      let schema = S.schema(s =>
        {
          "nickname": s.matches(S.option(S.string)),
        }
      )
      expect(labelOf(schema))->toEqual(("nickname", ["nickname"]))
    })

    testSync("a reference is not a name even when its field is not called `*Id`", () => {
      let schema = S.schema(s =>
        {
          "customer": s.matches(Reventless.Reference.to_("Customer")),
          "note": s.matches(S.string),
        }
      )
      expect(labelOf(schema))->toEqual(("note", ["note"]))
    })

    testSync("a DCB-tagged string is not a name", () => {
      let schema = S.schema(s =>
        {
          "partition": s.matches(Reventless.DcbTag.string),
          "note": s.matches(S.string),
        }
      )
      expect(labelOf(schema))->toEqual(("note", ["note"]))
    })

    testSync("the `*Id` test is case-insensitive — `productID` is a reference", () => {
      let schema = S.schema(s =>
        {
          "productID": s.matches(S.string),
          "note": s.matches(S.string),
        }
      )
      expect(labelOf(schema))->toEqual(("note", ["note"]))
    })

    testSync("a semantic-carrying string is a value, not a name", () => {
      // `imageUrl` names a stored object. A bucket key read as a product's name
      // is what the previous rule did whenever no plain string preceded it.
      let schema = S.schema(s =>
        {
          "imageUrl": s.matches(Reventless.StorageRef.forStore(~store="productImages")),
          "note": s.matches(S.string),
        }
      )
      expect(labelOf(schema))->toEqual(("note", ["note"]))
    })

    testSync("a state whose only string is a semantic falls to id", () => {
      let schema = S.schema(s =>
        {
          "imageUrl": s.matches(Reventless.StorageRef.forStore(~store="productImages")),
        }
      )
      expect(labelOf(schema))->toEqual(("id", []))
    })

    testSync("`id` itself is still excluded by name", () => {
      // `SchemaType` reads a name that short as an ordinary string, so the
      // exclusion cannot come from the IR.
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "note": s.matches(S.string),
        }
      )
      expect(labelOf(schema))->toEqual(("note", ["note"]))
    })
  })

  describe("labelField — the conventional-name rung", () => {
    let labelOf = schema => {
      let r = Plugin_Structure.labelFieldsFromStateSchema(~entityName="Test", schema->S.castToUnknown)
      (r.field, r.searchableFields)
    }

    testSync("a field named `name` beats an earlier string", () => {
      let schema = S.schema(s =>
        {
          "sku": s.matches(S.string),
          "name": s.matches(S.string),
        }
      )
      expect(labelOf(schema))->toEqual(("name", ["name"]))
    })

    testSync("`title` counts too, case-insensitively", () => {
      let schema = S.schema(s =>
        {
          "body": s.matches(S.string),
          "Title": s.matches(S.string),
        }
      )
      expect(labelOf(schema))->toEqual(("Title", ["Title"]))
    })

    testSync("the match is exact — `customerName` is a customer's name, not this record's", () => {
      // The shipped `OrdersView` fixture depends on this: it has exactly one
      // eligible field and must be picked by position, not by convention.
      let schema = S.schema(s =>
        {
          "customerName": s.matches(S.string),
          "note": s.matches(S.string),
        }
      )
      expect(labelOf(schema))->toEqual(("customerName", ["customerName"]))
    })

    testSync("an optional `name` still outranks an earlier string", () => {
      let schema = S.schema(s =>
        {
          "sku": s.matches(S.string),
          "name": s.matches(S.option(S.string)),
        }
      )
      expect(labelOf(schema))->toEqual(("name", ["name"]))
    })
  })

  // The rung is published because the four are not equally believable: a
  // consumer with a name rule of its own has to know whether it is ranking
  // against a declaration or against a guess.
  describe("labelFieldSource — which rung answered", () => {
    let sourceOf = schema =>
      Plugin_Structure.labelFieldsFromStateSchema(
        ~entityName="Test",
        schema->S.castToUnknown,
      ).source->Plugin_Structure.labelFieldSourceToString

    testSync("a @displayName spec is a declaration", () => {
      let customers = structure.stateViewSlices->Array.getUnsafe(2)
      expect((customers.labelField, customers.labelFieldSource))->toEqual((
        "displayName",
        Some("annotation"),
      ))
    })

    testSync("a field named `name` is a guess the consumer can also make", () => {
      let schema = S.schema(s =>
        {
          "sku": s.matches(S.string),
          "name": s.matches(S.string),
        }
      )
      expect(sourceOf(schema))->toEqual("convention")
    })

    testSync("declaration order is a guess only this side can make", () => {
      // `customerName` is eligible and unconventional, so it wins by position —
      // and a consumer told only "customerName" could not tell that from a
      // declaration.
      let schema = S.schema(s =>
        {
          "customerName": s.matches(S.string),
          "note": s.matches(S.string),
        }
      )
      expect(sourceOf(schema))->toEqual("position")
    })

    testSync("no candidate at all is the state saying it has no human field", () => {
      let schema = S.schema(s =>
        {
          "orderId": s.matches(Reventless.Reference.to_("Order")),
          "placedAt": s.matches(Reventless.DateTime.string),
        }
      )
      expect(sourceOf(schema))->toEqual("fallback")
    })

    testSync("every built def states one", () => {
      let stated =
        Array.concat(structure.readModels, structure.stateViewSlices)->Array.every(q =>
          q.labelFieldSource->Option.isSome
        )
      expect(stated)->toEqual(true)
    })
  })

  describe("statusField — the shape rule", () => {
    let statusOf = schema =>
      Plugin_Structure.statusFieldFromStateSchema(~entityName="Test", schema->S.castToUnknown)

    testSync("a `status` field holding a closed set of values is the lifecycle field", () => {
      let schema = S.schema(s =>
        {
          "status": s.matches(S.union([S.literal("Placed"), S.literal("Shipped")])),
        }
      )
      expect(statusOf(schema))->toEqual(Some("status"))
    })

    testSync("an optional one counts too", () => {
      let schema = S.schema(s =>
        {
          "status": s.matches(S.option(S.union([S.literal("Placed"), S.literal("Shipped")]))),
        }
      )
      expect(statusOf(schema))->toEqual(Some("status"))
    })

    testSync("free text named `status` is not a lifecycle", () => {
      // `allowedStates` filtering needs states to compare against; a string
      // field named `status` gives a command menu nothing to match.
      let schema = S.schema(s => {"status": s.matches(S.string)})
      expect(statusOf(schema))->toEqual(None)
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

    testSync("itemId carries x-reventless-id", () => {
      expect(
        annotatedSchema
        ->getPropertyOf("itemId")
        ->Option.flatMap(s => getProperty(s, "x-reventless-id"))
        ->Option.flatMap(JSON.Decode.bool),
      )->toBe(Some(true))
    })

    testSync("version carries x-reventless-subId", () => {
      expect(
        annotatedSchema
        ->getPropertyOf("version")
        ->Option.flatMap(s => getProperty(s, "x-reventless-subId"))
        ->Option.flatMap(JSON.Decode.bool),
      )->toBe(Some(true))
    })

    testSync("ownerId carries x-reventless-index = byOwner", () => {
      expect(
        annotatedSchema
        ->getPropertyOf("ownerId")
        ->Option.flatMap(s => getProperty(s, "x-reventless-index"))
        ->Option.flatMap(JSON.Decode.string),
      )->toBe(Some("byOwner"))
    })

    testSync("@semantic(\"currency\") flows through the PPX to x-reventless-semantic", () => {
      expect(
        annotatedSchema
        ->getPropertyOf("total")
        ->Option.flatMap(s => getProperty(s, "x-reventless-semantic"))
        ->Option.flatMap(JSON.Decode.string),
      )->toBe(Some("currency"))
    })

    testSync("@metric flows through the PPX to x-reventless-metric {aggregate,label}", () => {
      let metricObj =
        annotatedSchema
        ->getPropertyOf("total")
        ->Option.flatMap(s => getProperty(s, "x-reventless-metric"))
      expect((
        metricObj->Option.flatMap(m => getProperty(m, "aggregate"))->Option.flatMap(JSON.Decode.string),
        metricObj->Option.flatMap(m => getProperty(m, "label"))->Option.flatMap(JSON.Decode.string),
      ))->toEqual((Some("sum"), Some("Revenue")))
    })

    testSync("unannotated field 'name' has no x-reventless-* keys", () => {
      let nameField = annotatedSchema->getPropertyOf("name")
      expect((
        nameField->Option.flatMap(s => getProperty(s, "x-reventless-id")),
        nameField->Option.flatMap(s => getProperty(s, "x-reventless-subId")),
        nameField->Option.flatMap(s => getProperty(s, "x-reventless-index")),
      ))->toEqual((None, None, None))
    })

    testSync("unannotated state-view slice (Orders) emits no x-reventless-* keys", () => {
      let ordersSchema = structure.stateViewSlices->Array.getUnsafe(0)->parseSchema
      let orderIdField = ordersSchema->getPropertyOf("orderId")
      expect(
        orderIdField->Option.flatMap(s => getProperty(s, "x-reventless-id")),
      )->toBe(None)
    })
  })

  // The generator captures each component's chapter (source-folder grouping band)
  // and passes it as ~componentChapters; Plugin_Structure looks it up by Spec.name
  // and threads it onto every def, so a deployed-graph consumer can render chapter
  // bands without workspace access. See docs/plans/deployed-chapter-grouping.md.
  describe("componentChapters threading", () => {
    let chaptered = Plugin_Structure.make(
      ~name="TestPlugin",
      ~stateChangeSlices=[module(PsPlaceOrderSlice), module(PsShipOrderSlice)],
      ~stateViewSlices=[module(PsOrdersViewSlice)],
      // PlaceOrder + Orders live under a chapter; ShipOrder does not.
      ~componentChapters=Dict.fromArray([("PlaceOrder", "Order"), ("Orders", "Order")]),
    )

    testSync("a chaptered state-change slice carries Some(chapter)", () => {
      let placeOrder = chaptered.stateChangeSlices->Array.getUnsafe(0)
      expect(placeOrder.chapter)->toEqual(Some("Order"))
    })

    testSync("a chaptered state-view slice carries Some(chapter)", () => {
      let orders = chaptered.stateViewSlices->Array.getUnsafe(0)
      expect(orders.chapter)->toEqual(Some("Order"))
    })

    testSync("a component absent from the map carries None", () => {
      let shipOrder = chaptered.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.chapter)->toEqual(None)
    })

    testSync("no ~componentChapters → every def is chapterless (None)", () => {
      let placeOrder = structure.stateChangeSlices->Array.getUnsafe(0)
      expect(placeOrder.chapter)->toEqual(None)
    })
  })

  // A field typed as a storage ref states that the deployment needs that store
  // to exist. Collecting the requirement onto the structure is what lets the
  // deploy read it without re-walking every component's schema.
  describe("requiredStores", () => {
    let withStores = Plugin_Structure.make(
      ~name="TestPlugin",
      ~stateChangeSlices=[module(PsAttachInvoiceSlice)],
    )
    let stores = withStores.requiredStores->Option.getOr([])

    testSync("an unqualified store resolves against the declaring plugin", () =>
      expect(stores->Array.includes("TestPlugin.documents"))->toBe(true)
    )

    testSync("a qualified store keeps its own plugin", () =>
      expect(stores->Array.includes("branding.logos"))->toBe(true)
    )

    // `documents` is declared on both a command field and an event field.
    testSync("a store declared by several fields is collected once", () =>
      expect(stores->Array.filter(s => s == "TestPlugin.documents")->Array.length)->toBe(1)
    )

    testSync("only the declared stores are collected", () =>
      expect(stores->Array.length)->toBe(2)
    )

    testSync("a plugin declaring no stores collects none — not None", () =>
      expect(structure.requiredStores)->toEqual(Some([]))
    )
  })
})
