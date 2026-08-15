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
module PsCategoriesViewSlice: ReventlessInfra.StateViewSlice.T = {
  module Spec = PsCategoriesView
  module Projection = {
    let project = PsCategoriesView.project
    let moduleUrl = PsCategoriesView.moduleUrl
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

module PsUploadAvatarSlice: ReventlessInfra.StateChangeSlice.T = {
  module Spec = PsUploadAvatar
  module Behavior = {
    type state = PsUploadAvatar.state
    let initialState = PsUploadAvatar.initialState
    let evolve = PsUploadAvatar.evolve
    let decide = PsUploadAvatar.decide
    let moduleUrl = PsUploadAvatar.moduleUrl
  }
  let isAsync = false
  type component = scsComponent
  let make = (~dcbEventLog as _, ~publishJsons as _, ~tagKeysByEventType as _=?, ~crossPartitionTagKeys as _=?, ~runtime as _=?, ~opts as _=?): component => Obj.magic(0)
}

module PsChangePhotoSlice: ReventlessInfra.StateChangeSlice.T = {
  module Spec = PsChangePhoto
  module Behavior = {
    type state = PsChangePhoto.state
    let initialState = PsChangePhoto.initialState
    let evolve = PsChangePhoto.evolve
    let decide = PsChangePhoto.decide
    let moduleUrl = PsChangePhoto.moduleUrl
  }
  let isAsync = false
  type component = scsComponent
  let make = (~dcbEventLog as _, ~publishJsons as _, ~tagKeysByEventType as _=?, ~crossPartitionTagKeys as _=?, ~runtime as _=?, ~opts as _=?): component => Obj.magic(0)
}

module PsReserveStockSlice: ReventlessInfra.StateChangeSlice.T = {
  module Spec = PsReserveStock
  module Behavior = {
    type state = PsReserveStock.state
    let initialState = PsReserveStock.initialState
    let evolve = PsReserveStock.evolve
    let decide = PsReserveStock.decide
    let moduleUrl = PsReserveStock.moduleUrl
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

    // A consumer that builds its own mutation document declares one variable
    // per argument, and JSON Schema does not carry the GraphQL type those
    // variables need — `orderId` reads as a plain string there while the server
    // declares `ID!`. So the rendered type rides along on the property.
    testSync("ShipOrder: the command schema publishes each argument's GraphQL type", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      let ship = shipOrder.commands->Array.find(c => c.name == "ShipOrder")->Option.getOrThrow
      expect(ship.schema->String.includes(`"x-reventless-graphql-type":"ID!"`))->toBe(true)
    })

    // The names are composed from the mutation field, and a `@noApi` variant
    // has none — publishing a type derived from the empty sentinel would name
    // types no schema declares.
    testSync("CancelShipment: a @noApi variant publishes no argument types", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      let cancel =
        shipOrder.commands->Array.find(c => c.name == "CancelShipment")->Option.getOrThrow
      expect(cancel.schema->String.includes("x-reventless-graphql-type"))->toBe(false)
    })

    testSync("ShipOrder: payload-less event ShipmentVoided is surfaced in events", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.events->Array.map(e => e.name))->toEqual(["OrderShipped", "ShipmentVoided"])
    })

    testSync("ShipOrder: producedEventTypes still excludes the payload-less ShipmentVoided (DCB filter intact)", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.producedEventTypes)->toEqual(["TestPlugin.OrderShipped"])
    })

    // A slice's declared errors are the third family of its contract, beside the
    // commands it accepts and the events it emits — what a caller has to handle
    // when a decision is refused.
    testSync("PlaceOrder: the single payload-less error variant is surfaced", () => {
      let placeOrder = structure.stateChangeSlices->Array.getUnsafe(0)
      expect(placeOrder.errors->Array.map(e => e.name))->toEqual(["AlreadyPlaced"])
    })

    testSync("ShipOrder: both error variants surface, in declaration order", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      expect(shipOrder.errors->Array.map(e => e.name))->toEqual(["OrderNotFound", "NotShippable"])
    })

    testSync("ShipOrder: a payload-carrying error carries its field schema", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      let notShippable =
        shipOrder.errors->Array.find(e => e.name == "NotShippable")->Option.getOrThrow
      expect(notShippable.schema->String.includes("\"reason\""))->toBe(true)
    })

    testSync("ShipOrder: a payload-less error carries no fields and no references", () => {
      let shipOrder = structure.stateChangeSlices->Array.getUnsafe(1)
      let notFound = shipOrder.errors->Array.find(e => e.name == "OrderNotFound")->Option.getOrThrow
      expect((notFound.schema->String.includes("\"reason\""), notFound.references->Array.length))
      ->toEqual((false, 0))
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

  // The singular is published because it is not derivable from the plural without
  // re-implementing `Api_Naming.singularize` — and a consumer that guesses gets an
  // irregular plural wrong for both the detail query and the filter input type.
  describe("singleQueryField — the singular the schema actually serves", () => {
    let withIrregularPlural = Plugin_Structure.make(
      ~name="TestPlugin",
      ~stateChangeSlices=[],
      ~stateViewSlices=[module(PsCategoriesViewSlice)],
    )
    let categories = withIrregularPlural.stateViewSlices->Array.getUnsafe(0)

    // "strip a trailing `s`" would publish `TestPlugin_Categorie`, a field the
    // generated SDL does not contain.
    testSync("an `-ies` plural publishes the `y` singular, not a truncation", () => {
      expect((categories.queryField, categories.singleQueryField))->toEqual((
        "TestPlugin_Categories",
        Some("TestPlugin_Category"),
      ))
    })

    testSync("every built def states the name Api_Naming returned", () => {
      let stated = structure.stateViewSlices->Array.every(q =>
        q.singleQueryField ==
          Some(
            Api_Naming.queryFieldNamesForStateView(
              ~plugin="TestPlugin",
              ~viewName=q.name,
            ).singleFieldName,
          )
      )
      expect(stated)->toEqual(true)
    })
  })

  // Which field identifies a row, and whether the author said so or this side
  // worked it out — the same declaration-vs-guess distinction `labelFieldSource`
  // publishes, for the field the generated filter and order-by are built from.
  describe("idField / idFieldSource — the key and its provenance", () => {
    let keyOf = (q: Reventless.Plugin.queryableDef) => (q.idField, q.idFieldSource)
    let withCategories = Plugin_Structure.make(
      ~name="TestPlugin",
      ~stateChangeSlices=[],
      ~stateViewSlices=[module(PsCategoriesViewSlice)],
    )

    // Orders holds `orderId` + `customerName`; the component name matches the
    // former, so the rung is the one a client could also reach on its own.
    testSync("a name-matching `*Id` field is a guess the consumer can also make", () =>
      expect(keyOf(structure.stateViewSlices->Array.getUnsafe(0)))->toEqual((
        Some("orderId"),
        Some("convention"),
      ))
    )

    // AvailableProducts: the name would ask for `availableProductId`, which is not
    // a field — `productId` wins because it is the only candidate there is.
    testSync("a sole `*Id` field is a fact only this side can see", () =>
      expect(keyOf(structure.stateViewSlices->Array.getUnsafe(1)))->toEqual((
        Some("productId"),
        Some("sole"),
      ))
    )

    testSync("an `-ies` component name singularises to its key", () =>
      expect(keyOf(withCategories.stateViewSlices->Array.getUnsafe(0)))->toEqual((
        Some("categoryId"),
        Some("convention"),
      ))
    )

    // AnnotatedView declares `@id itemId` beside an `@index` field `ownerId`, and
    // its name matches neither — inference alone would decline here, so reporting
    // `itemId` proves the declaration produced it.
    testSync("a declared @id is used where inference would decline", () =>
      expect(keyOf(structure.stateViewSlices->Array.getUnsafe(3)))->toEqual((
        Some("itemId"),
        Some("annotation"),
      ))
    )
  })

  describe("lifecycleField — the name rule and the shape rule", () => {
    let lifecycleOf = schema =>
      Plugin_Structure.lifecycleFieldFromStateSchema(~entityName="Test", schema->S.castToUnknown)

    let withLifecycle = (schema, ~field) =>
      schema->S.castToUnknown->S.Metadata.set(
        ~id=Reventless.StateAnnotations.stateAnnotationsId,
        {
          ids: [],
          compositeIds: [],
          subIds: [],
          compositeSubIds: [],
          indexes: [],
          hidden: [],
          summary: [],
          drillTargets: [],
          drillTargetKeys: [],
          collapsed: [],
          scan: [],
          scanSort: [],
          semantic: [],
          metric: [],
          lifecycle: Some(field),
          groupBy: None,
          visibility: None,
          live: None,
          retired: None,
        },
      )

    testSync("a `lifecycle` field holding a closed set of values is the lifecycle field", () => {
      let schema = S.schema(s =>
        {
          "lifecycle": s.matches(S.union([S.literal("Placed"), S.literal("Shipped")])),
        }
      )
      expect(lifecycleOf(schema))->toEqual(Some("lifecycle"))
    })

    testSync("an optional one counts too", () => {
      let schema = S.schema(s =>
        {
          "lifecycle": s.matches(S.option(S.union([S.literal("Placed"), S.literal("Shipped")]))),
        }
      )
      expect(lifecycleOf(schema))->toEqual(Some("lifecycle"))
    })

    testSync("free text named `lifecycle` is not a lifecycle", () => {
      // `allowedStates` filtering needs states to compare against; a string
      // field named `lifecycle` gives a command menu nothing to match.
      let schema = S.schema(s => {"lifecycle": s.matches(S.string)})
      expect(lifecycleOf(schema))->toEqual(None)
    })

    // The one behaviour the rename deliberately changes, so it is asserted rather
    // than assumed. `status` is a promiscuous name — geocoding progress, todo-queue
    // progress, translation audit outcome — and a convention keyed on it guessed
    // often. A record whose lifecycle really does live in a field called `status`
    // says so with `@lifecycle`.
    testSync("an unannotated field named `status` resolves to None", () => {
      let schema = S.schema(s =>
        {
          "status": s.matches(S.union([S.literal("Placed"), S.literal("Shipped")])),
        }
      )
      expect(lifecycleOf(schema))->toEqual(None)
    })

    testSync("the annotation names a field the convention would never reach", () => {
      let schema = S.schema(s =>
        {
          "locationStatus": s.matches(S.union([S.literal("Pending"), S.literal("Located")])),
        }
      )
      expect(lifecycleOf(schema->withLifecycle(~field="locationStatus")))->toEqual(
        Some("locationStatus"),
      )
    })
  })

  describe("retiredField — annotation and nothing else", () => {
    let retiredOf = schema =>
      Plugin_Structure.retiredFieldFromStateSchema(schema->S.castToUnknown)

    let withRetired = (schema, ~field) =>
      schema->S.castToUnknown->S.Metadata.set(
        ~id=Reventless.StateAnnotations.stateAnnotationsId,
        {
          ids: [],
          compositeIds: [],
          subIds: [],
          compositeSubIds: [],
          indexes: [],
          hidden: [],
          summary: [],
          drillTargets: [],
          drillTargetKeys: [],
          collapsed: [],
          scan: [],
          scanSort: [],
          semantic: [],
          metric: [],
          lifecycle: None,
          groupBy: None,
          visibility: None,
          live: None,
          retired: Some({field, label: "", showWhenFalse: false}),
        },
      )

    testSync("names the annotated field", () => {
      let schema = S.schema(s => {"archived": s.matches(S.bool)})
      expect(retiredOf(schema->withRetired(~field="archived")))->toEqual(Some("archived"))
    })

    // The whole reason this has no convention rung. `lifecycleField` may still fall
    // back to a field literally named `lifecycle` because guessing wrong there makes
    // a command menu filter oddly; guessing wrong here makes rows disappear for every caller who is not
    // elevated, so an unannotated boolean stays as visible as it was.
    testSync("declines a conventionally-named boolean nobody annotated", () => {
      let schema = S.schema(s =>
        {
          "archived": s.matches(S.bool),
          "deactivated": s.matches(S.bool),
        }
      )
      expect(retiredOf(schema))->toEqual(None)
    })

    testSync("declines a schema carrying no annotation spec at all", () => {
      let schema = S.schema(s => {"id": s.matches(S.string)})
      expect(retiredOf(schema))->toEqual(None)
    })
  })

  // Shared by the read-side and write-side schema cases below, which ask the
  // same question of the same emitter.
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

  // Phase 4: queryableDef.schema must carry x-reventless-* extension keys for
  // annotated state types. Plugin_Structure now uses SuryToJsonSchema.deriveObjectSchema
  // (annotation-aware) instead of S.toJSONSchema (metadata-blind).
  describe("queryableDef.schema propagates x-reventless-* annotations", () => {
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

    testSync("@live(false) flows through the PPX to top-level x-reventless-live", () => {
      expect(
        getProperty(annotatedSchema, "x-reventless-live")->Option.flatMap(JSON.Decode.bool),
      )->toBe(Some(false))
    })

    testSync("unannotated state-view slice (Orders) has no top-level x-reventless-live", () => {
      let ordersSchema = structure.stateViewSlices->Array.getUnsafe(0)->parseSchema
      expect(getProperty(ordersSchema, "x-reventless-live"))->toBe(None)
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

    testSync("each requirement keeps its declaring (component, field) sites", () => {
      // `documents` is declared on a command field AND an event field of the
      // same component under the same field name — one declaration site, so
      // the identical triples collapse to one entry.
      // `annotation` is the source text, not the key: the own-plugin store is
      // written bare and the foreign one qualified, which is exactly the
      // distinction no downstream comparison can recover.
      let expected: array<Reventless.Plugin.requiredStoreDeclaration> = [
        {
          store: "TestPlugin.documents",
          component: "AttachInvoice",
          field: "documentUrl",
          annotation: Some("documents"),
        },
        {
          store: "branding.logos",
          component: "AttachInvoice",
          field: "logoUrl",
          annotation: Some("branding.logos"),
        },
      ]
      expect(withStores.requiredStoreDeclarations)->toEqual(Some(expected))
    })

    // The manifest is a rendering of the structure. Its key set must be
    // byte-identical to what the deployed plugin reports as `requiredStores`,
    // because the deploy-time coverage assertion compares against exactly that
    // — this equality is the whole contract of `capabilities.json`.
    describe("capability manifest", () => {
      let manifest = Reventless.CapabilityManifest.fromStructure(withStores)

      testSync("keys are byte-identical to requiredStores", () =>
        expect(manifest.capabilities->Array.map(c => c.key))->toEqual(
          withStores.requiredStores->Option.getOr([]),
        )
      )

      testSync("each entry carries its provenance", () => {
        let entry =
          manifest.capabilities->Array.find(c => c.key == "TestPlugin.documents")->Option.getOrThrow
        let expected: array<Reventless.CapabilityManifest.provenance> = [
          {component: "AttachInvoice", field: "documentUrl", annotation: "documents"},
        ]
        expect(entry.declaredBy)->toEqual(expected)
      })

      testSync("a structure declaring nothing yields an empty list, not a missing manifest", () =>
        expect(Reventless.CapabilityManifest.fromStructure(structure).capabilities)->toEqual([])
      )

      testSync("rendering is deterministic and newline-terminated", () => {
        let rendered = Reventless.CapabilityManifest.renderForStructure(withStores)
        expect(rendered)->toBe(
          `{
  "capabilities": [
    {
      "kind": "ObjectStore",
      "key": "TestPlugin.documents",
      "declaredBy": [
        {
          "component": "AttachInvoice",
          "field": "documentUrl",
          "annotation": "documents"
        }
      ]
    },
    {
      "kind": "ObjectStore",
      "key": "branding.logos",
      "declaredBy": [
        {
          "component": "AttachInvoice",
          "field": "logoUrl",
          "annotation": "branding.logos"
        }
      ]
    }
  ]
}
`,
        )
      })
    })
  })

  // Making a field optional says the value may be absent. It does not say the
  // field stopped being a storage ref or a reference — but both walks read the
  // marker through `Semantic.get`, and an optional field's marker sits on the
  // schema inside the wrapper sury-ppx builds. Until that unwrap existed, adding
  // a `?` to a field silently un-declared its store: nothing failed, an S3
  // bucket just stopped being provisioned.
  describe("optional carriers keep their declarations", () => {
    let withOptional = Plugin_Structure.make(
      ~name="TestPlugin",
      ~stateChangeSlices=[module(PsUploadAvatarSlice)],
    )

    testSync("an optional storage ref still requires its store", () =>
      expect(withOptional.requiredStores)->toEqual(Some(["TestPlugin.avatars"]))
    )

    // Declared on the command and on the event under one field name — the same
    // collapse the required case makes, so optionality does not change arity.
    testSync("and still carries one declaring site", () => {
      let expected: array<Reventless.Plugin.requiredStoreDeclaration> = [
        {
          store: "TestPlugin.avatars",
          component: "UploadAvatar",
          field: "avatarUrl",
          annotation: Some("avatars"),
        },
      ]
      expect(withOptional.requiredStoreDeclarations)->toEqual(Some(expected))
    })

    testSync("an optional reference is still collected", () => {
      let cmd = (withOptional.stateChangeSlices->Array.getUnsafe(0)).commands->Array.getUnsafe(0)
      let expected: array<Reventless.Plugin.fieldReference> = [
        {fieldName: "referredBy", entity: "Customers", plugin: None},
      ]
      expect(cmd.references)->toEqual(expected)
    })

    // What `requiredStores` knows, the wire has to carry. A reader deciding
    // which command fills a storage-ref field, or which store's endpoint an
    // upload goes to, has only the command schema to go on.
    testSync("the command schema carries the field's storage-ref marker", () => {
      let cmd = (withOptional.stateChangeSlices->Array.getUnsafe(0)).commands->Array.getUnsafe(0)
      let target =
        cmd.schema
        ->JSON.parseOrThrow
        ->getPropertyOf("avatarUrl")
        ->Option.flatMap(s => getProperty(s, "x-reventless-semantic-target"))
        ->Option.flatMap(t => getProperty(t, "store"))
        ->Option.flatMap(JSON.Decode.string)
      expect(target)->toBe(Some("avatars"))
    })

    // A form submits what a schema says is required. `avatarUrl?` is optional in
    // the spec, so listing it would make the picture mandatory in every UI that
    // renders the command — the failure this pairs with, since carrying the
    // marker is worth nothing if the field cannot be left empty.
    testSync("an optional command argument is not required", () => {
      let cmd = (withOptional.stateChangeSlices->Array.getUnsafe(0)).commands->Array.getUnsafe(0)
      let required =
        cmd.schema
        ->JSON.parseOrThrow
        ->getProperty("required")
        ->Option.flatMap(JSON.Decode.array)
        ->Option.getOr([])
        ->Array.filterMap(JSON.Decode.string)
      expect(required)->toEqual(["customerId"])
    })
  })

  // Declarations are authoritative; the name heuristics are a lint. A
  // heuristic-only match warns and never reaches the manifest, so nothing is
  // provisioned from a guess — `imageUrl` is genuinely ambiguous between an
  // uploaded object and an external URL, and only the author can settle it.
  describe("capability inference", () => {
    let commandWarnings = Capability_Inference.scanSchema(
      ~component="ChangePhoto",
      PsChangePhoto.commandSchema->S.castToUnknown,
    )
    let eventWarnings = Capability_Inference.scanSchema(
      ~component="ChangePhoto",
      PsChangePhoto.eventSchema->S.castToUnknown,
    )

    testSync("a heuristic-only match produces a warning", () => {
      let expected: array<Capability_Inference.warning> = [
        {component: "ChangePhoto", field: "photoUrl"},
      ]
      expect(commandWarnings)->toEqual(expected)
    })

    testSync("a declared field with a heuristic name does not warn", () => {
      // The event's `thumbnail` matches the name heuristic but carries
      // @storageRef — only the undeclared `photoUrl` warns.
      let expected: array<Capability_Inference.warning> = [
        {component: "ChangePhoto", field: "photoUrl"},
      ]
      expect(eventWarnings)->toEqual(expected)
    })

    testSync("a heuristic-only match reaches no manifest entry", () => {
      let withHeuristicField = Plugin_Structure.make(
        ~name="TestPlugin",
        ~stateChangeSlices=[module(PsChangePhotoSlice)],
      )
      // Only the *declared* `thumbnail` store is collected; `photoUrl` — the
      // heuristic-only match — provisions nothing.
      expect(withHeuristicField.requiredStores)->toEqual(Some(["TestPlugin.productPhotos"]))
      let manifest = Reventless.CapabilityManifest.fromStructure(withHeuristicField)
      expect(
        manifest.capabilities->Array.every(entry =>
          entry.declaredBy->Array.every(site => site.field != "photoUrl")
        ),
      )->toBe(true)
    })

    testSync("the warning names the field and the settling annotation", () => {
      let text =
        commandWarnings->Array.getUnsafe(0)->Capability_Inference.message
      expect(text->String.includes("ChangePhoto.photoUrl"))->toBe(true)
      expect(text->String.includes("@storageRef"))->toBe(true)
    })

    testSync("suffix and exact name rules match; ordinary names do not", () => {
      expect(
        ["invoiceFileRef", "upload", "thumbnail", "customerName", "documentUrl"]->Array.map(
          Capability_Inference.nameMatches,
        ),
      )->toEqual([true, true, true, false, false])
    })
  })

  // A plural reference is declared exactly like a singular one, and the ppx puts
  // the marker where `Reference.to_` returns it: on the element schema, one level
  // inside the array. Reading the field's own schema therefore answers "no
  // reference" for every `@ref` array — and the consuming side treats a missing
  // declaration as licence to guess, so the field resolves to whatever its name
  // suggests instead of what the author wrote.
  describe("plural references reach the manifest", () => {
    let withPluralRefs = Plugin_Structure.make(
      ~name="TestPlugin",
      ~stateChangeSlices=[module(PsReserveStockSlice)],
    )
    let slice = withPluralRefs.stateChangeSlices->Array.getUnsafe(0)
    let referencesOf = refs =>
      refs->Array.map(({Reventless.Plugin.fieldName: f, entity}) => (f, entity))

    // Scalar and plural in one command: the plural forms are the regression, the
    // scalar one is here so a fix that reaches them by breaking it cannot pass.
    testSync("a command collects its array refs alongside its scalar one", () => {
      let cmd = slice.commands->Array.getUnsafe(0)
      expect(cmd.references->referencesOf)->toEqual([
        ("customerId", "Customers"),
        ("productIds", "AvailableProducts"),
        ("warehouseIds", "Warehouses"),
      ])
    })

    // Optionality is a statement about presence. An optional array puts the
    // element two wrappers down, which is the shape most likely to be missed by
    // an unwrap that only handles one.
    testSync("an optional array ref is collected under the field's own name", () => {
      let cmd = slice.commands->Array.getUnsafe(0)
      expect(
        cmd.references->Array.find(({fieldName}) => fieldName == "warehouseIds"),
      )->toEqual(Some({Reventless.Plugin.fieldName: "warehouseIds", entity: "Warehouses", plugin: None}))
    })

    // The event walk is a separate function over the same field dicts. Left to
    // itself it would be fixed by accident or not at all.
    testSync("an event collects its array ref too", () => {
      let evt = slice.events->Array.getUnsafe(0)
      expect(evt.references->referencesOf)->toEqual([("productIds", "AvailableProducts")])
    })

    // The declared entity, not the one `productIds` reads like. Before the
    // element unwrap this field resolved by heuristic to `Products`.
    testSync("the declared entity wins over the one the field name suggests", () => {
      let cmd = slice.commands->Array.getUnsafe(0)
      expect(
        cmd.references
        ->Array.find(({fieldName}) => fieldName == "productIds")
        ->Option.map(({entity}) => entity),
      )->toEqual(Some("AvailableProducts"))
    })
  })
})
