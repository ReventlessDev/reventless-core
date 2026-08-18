// Worked example for cross-plugin Flow_GWT — two self-contained "plugins"
// (Catalog and Ordering) joined by their ExtensionPoint mapping + Extension
// delegate, threaded through one shared log.
//
//   Catalog: AddProduct ─→ ProductAdded
//     └─[Products EP mapping]→ ProductBecameAvailable
//          └─[Ordering Products extension]→ SyncProduct
//               └─ Ordering: SyncProduct ─→ ProductSynced
//   Ordering: PlaceOrder  ─→ OrderPlaced   ← succeeds only because of the sync
//     └─[Orders EP mapping, fan-out]→ ItemOrdered ×N
//          └─[Catalog demand extension]→ RecordDemand ×N
//
// Proves the property no single-component test can: a product added in Catalog
// becomes orderable in Ordering only via the cross-plugin sync, and a batch
// order fans out into one demand command per product across the boundary.
// See `docs/plans/done/gwt-flow-and-extension-test-kinds.md` Phase 3.


open Flow_GWT

module EPM = ReventlessInfra.ExtensionPointMapping
module EM = ReventlessInfra.ExtensionMapping

// ===========================================================================
// Catalog plugin
// ===========================================================================

module AddProductSlice = {
  let name = "AddProduct"

  @schema
  type consumedEvent = ProductAdded({productId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type command =
    AddProduct({productId: @s.matches(Reventless.DcbTag.string) string, name: string, price: float})

  @schema
  type error = AlreadyAdded

  @schema
  type event =
    ProductAdded({productId: @s.matches(Reventless.DcbTag.string) string, name: string, price: float})
}

module AddProductBehavior = {
  module Spec = AddProductSlice
  type state = {added: bool}
  let initialState = {added: false}
  let evolve = (_state, event: AddProductSlice.consumedEvent) =>
    switch event {
    | ProductAdded(_) => {added: true}
    }
  let decide = (state, command: AddProductSlice.command) =>
    switch command {
    | AddProduct({productId, name, price}) =>
      state.added
        ? Error(AddProductSlice.AlreadyAdded)
        : Ok([AddProductSlice.ProductAdded({productId, name, price})])
    }
}

// Catalog → Ordering extension point (product availability).
module ProductsEpSpec = {
  let name = "Catalog.Products"
  let moduleUrl = ""
  @schema type command = NoCommand
  @schema
  type event = ProductBecameAvailable({productId: string, name: string, price: float})
  @schema type directive = NoDirective
}

module ProductDelegate = {
  module Id = Reventless.Id.StringPure
  let name = "Product"
  @schema type command = NoCommand
  @schema type event = ProductAdded({productId: string, name: string, price: float})
  @schema type error = NoError
  let moduleUrl = ""
  let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAuthenticated
}

module ProductsEpMapping = {
  module ExtensionPoint = ProductsEpSpec
  module Delegate = ProductDelegate
  let moduleUrl = "test:FlowCrossPluginGwtTest:ProductsEpMapping"
  let mapIncomingCommand = (_id, _command, _meta) => []
  let mapOutgoingEvent = Some(
    (_id, event: ProductDelegate.event, _meta, _q) =>
      switch event {
      | ProductAdded({productId, name, price}) => [
          EPM.PublishEvent(productId, ProductsEpSpec.ProductBecameAvailable({productId, name, price})),
        ]
      },
  )
}

// Ordering → Catalog extension point (per-product order demand).
module OrdersEpSpec = {
  let name = "Ordering.Orders"
  let moduleUrl = ""
  @schema type command = NoCommand
  @schema type event = ItemOrdered({productId: string, orderId: string})
  @schema type directive = NoDirective
}

module OrderDelegate = {
  module Id = Reventless.Id.StringPure
  let name = "Order"
  @schema type command = NoCommand
  @schema type event = OrderPlaced({orderId: string, productIds: array<string>})
  @schema type error = NoError
  let moduleUrl = ""
  let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAuthenticated
}

module OrdersEpMapping = {
  module ExtensionPoint = OrdersEpSpec
  module Delegate = OrderDelegate
  let moduleUrl = "test:FlowCrossPluginGwtTest:OrdersEpMapping"
  let mapIncomingCommand = (_id, _command, _meta) => []
  let mapOutgoingEvent = Some(
    (_id, event: OrderDelegate.event, _meta, _q) =>
      switch event {
      | OrderPlaced({orderId, productIds}) =>
        productIds->Array.map(pid =>
          EPM.PublishEvent(pid, OrdersEpSpec.ItemOrdered({productId: pid, orderId}))
        )
      },
  )
}

// Catalog's RecordDemand slice — the delegate Catalog's Orders extension drives.
module RecordDemandSlice = {
  module Id = Reventless.Id.StringPure
  let name = "RecordDemand"
  @schema
  type consumedEvent =
    DemandRecorded({productId: @s.matches(Reventless.DcbTag.string) string, orderId: string})
  @schema
  type command =
    RecordDemand({productId: @s.matches(Reventless.DcbTag.string) string, orderId: string})
  @schema type error = NoError
  @schema
  type event =
    DemandRecorded({productId: @s.matches(Reventless.DcbTag.string) string, orderId: string})
  let moduleUrl = ""
  let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAuthenticated
}

module RecordDemandBehavior = {
  module Spec = RecordDemandSlice
  type state = {count: int}
  let initialState = {count: 0}
  let evolve = (state, event: RecordDemandSlice.consumedEvent) =>
    switch event {
    | DemandRecorded(_) => {count: state.count + 1}
    }
  let decide = (_state, command: RecordDemandSlice.command) =>
    switch command {
    | RecordDemand({productId, orderId}) => Ok([RecordDemandSlice.DemandRecorded({productId, orderId})])
    }
}

module OrdersExtMapping = {
  module ExtensionPoint = OrdersEpSpec
  module Delegate = RecordDemandSlice
  let moduleUrl = ""
  let delegateModuleUrl = ""
  let mapIncomingEvent = (_id, event: OrdersEpSpec.event, _meta, _pd, _q) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        EM.PublishStateChangeSliceCommand(RecordDemandSlice.RecordDemand({productId, orderId})),
      ]
    }
  let mapOutgoingEvent = None
}

// ===========================================================================
// Ordering plugin
// ===========================================================================

// Local shadow of catalog products, kept in sync via the extension.
module SyncProductSlice = {
  module Id = Reventless.Id.StringPure
  let name = "SyncProduct"
  @schema
  type consumedEvent = ProductSynced({productId: @s.matches(Reventless.DcbTag.string) string})
  @schema
  type command =
    SyncProduct({productId: @s.matches(Reventless.DcbTag.string) string, name: string, price: float})
  @schema type error = NoError
  @schema
  type event =
    ProductSynced({productId: @s.matches(Reventless.DcbTag.string) string, name: string, price: float})
  let moduleUrl = ""
  let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAuthenticated
}

module SyncProductBehavior = {
  module Spec = SyncProductSlice
  type state = {synced: bool}
  let initialState = {synced: false}
  let evolve = (_state, event: SyncProductSlice.consumedEvent) =>
    switch event {
    | ProductSynced(_) => {synced: true}
    }
  let decide = (_state, command: SyncProductSlice.command) =>
    switch command {
    | SyncProduct({productId, name, price}) =>
      Ok([SyncProductSlice.ProductSynced({productId, name, price})])
    }
}

module ProductsExtMapping = {
  module ExtensionPoint = ProductsEpSpec
  module Delegate = SyncProductSlice
  let moduleUrl = ""
  let delegateModuleUrl = ""
  let mapIncomingEvent = (_id, event: ProductsEpSpec.event, _meta, _pd, _q) =>
    switch event {
    | ProductBecameAvailable({productId, name, price}) => [
        EM.PublishStateChangeSliceCommand(SyncProductSlice.SyncProduct({productId, name, price})),
      ]
    }
  let mapOutgoingEvent = None
}

module PlaceOrderSlice = {
  let name = "PlaceOrder"
  @schema
  type consumedEvent =
    | OrderPlaced({orderId: @s.matches(Reventless.DcbTag.string) string})
    | ProductSynced({productId: @s.matches(Reventless.DcbTag.string) string})
  @schema
  type command =
    PlaceOrder({
      orderId: @s.matches(Reventless.DcbTag.string) string,
      productIds: array<@s.matches(Reventless.DcbTag.stringForKey(~key="productId")) string>,
    })
  @schema
  type error =
    | OrderAlreadyPlaced
    | ProductsNotAvailable({missing: array<string>})
  @schema
  type event =
    OrderPlaced({
      orderId: @s.matches(Reventless.DcbTag.string) string,
      productIds: array<@s.matches(Reventless.DcbTag.stringForKey(~key="productId")) string>,
    })
}

module PlaceOrderBehavior = {
  module Spec = PlaceOrderSlice
  type state = {placed: array<string>, available: array<string>}
  let initialState = {placed: [], available: []}
  let evolve = (state, event: PlaceOrderSlice.consumedEvent) =>
    switch event {
    | OrderPlaced({orderId}) => {...state, placed: state.placed->Array.concat([orderId])}
    | ProductSynced({productId}) => {...state, available: state.available->Array.concat([productId])}
    }
  let decide = (state, command: PlaceOrderSlice.command) =>
    switch command {
    | PlaceOrder({orderId, productIds}) =>
      if state.placed->Array.includes(orderId) {
        Error(PlaceOrderSlice.OrderAlreadyPlaced)
      } else {
        let missing = productIds->Array.filter(p => !(state.available->Array.includes(p)))
        missing->Array.length > 0
          ? Error(PlaceOrderSlice.ProductsNotAvailable({missing: missing}))
          : Ok([PlaceOrderSlice.OrderPlaced({orderId, productIds})])
      }
    }
}

// ===========================================================================
// Step modules
// ===========================================================================

module AddProduct = CommandStep(AddProductSlice, AddProductBehavior)
module ProductsEp = ExtensionPointStep(ProductsEpMapping)
module ProductsExt = ExtensionStep(ProductsExtMapping)
module Sync = CommandStep(SyncProductSlice, SyncProductBehavior)
module Place = CommandStep(PlaceOrderSlice, PlaceOrderBehavior)
module OrdersEp = ExtensionPointStep(OrdersEpMapping)
module OrdersExt = ExtensionStep(OrdersExtMapping)
module Demand = CommandStep(RecordDemandSlice, RecordDemandBehavior)

// ===========================================================================
// Flows
// ===========================================================================

describe("Cross-plugin flow", () => {
  test("Tier 2 — a product added in Catalog becomes orderable in Ordering via sync", () =>
    start
    ->AddProduct.whenCommand(AddProductSlice.AddProduct({productId: "p1", name: "Book", price: 9.99}))
    ->AddProduct.thenEvent(AddProductSlice.ProductAdded({productId: "p1", name: "Book", price: 9.99}))
    ->ProductsEp.whenPublishedThrough
    ->ProductsEp.thenPublicEvent(
      ProductsEpSpec.ProductBecameAvailable({productId: "p1", name: "Book", price: 9.99}),
    )
    ->ProductsExt.whenExtensionReacts
    ->ProductsExt.thenIssuesCommand(
      SyncProductSlice.SyncProduct({productId: "p1", name: "Book", price: 9.99}),
    )
    ->Sync.whenCommand(SyncProductSlice.SyncProduct({productId: "p1", name: "Book", price: 9.99}))
    ->Sync.thenEvent(SyncProductSlice.ProductSynced({productId: "p1", name: "Book", price: 9.99}))
    ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", productIds: ["p1"]}))
    ->Place.thenEvent(PlaceOrderSlice.OrderPlaced({orderId: "o1", productIds: ["p1"]}))
  )

  test("Tier 2 — placing an order without the cross-plugin sync is rejected", () =>
    start
    ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", productIds: ["p1"]}))
    ->Place.thenError(ProductsNotAvailable({missing: ["p1"]}))
  )

  test("Tier 3 — a batch order fans out to one demand command per product across the boundary", () =>
    start
    ->Sync.givenEvents([
      SyncProductSlice.ProductSynced({productId: "p1", name: "Book", price: 9.99}),
      SyncProductSlice.ProductSynced({productId: "p2", name: "Pen", price: 1.5}),
    ])
    ->Place.whenCommand(PlaceOrderSlice.PlaceOrder({orderId: "o1", productIds: ["p1", "p2"]}))
    ->Place.thenEvent(PlaceOrderSlice.OrderPlaced({orderId: "o1", productIds: ["p1", "p2"]}))
    ->OrdersEp.whenPublishedThrough
    ->OrdersEp.thenPublicEvents([
      OrdersEpSpec.ItemOrdered({productId: "p1", orderId: "o1"}),
      OrdersEpSpec.ItemOrdered({productId: "p2", orderId: "o1"}),
    ])
    ->OrdersExt.whenExtensionReacts
    ->OrdersExt.thenIssuesCommands([
      RecordDemandSlice.RecordDemand({productId: "p1", orderId: "o1"}),
      RecordDemandSlice.RecordDemand({productId: "p2", orderId: "o1"}),
    ])
    ->Demand.whenCommand(RecordDemandSlice.RecordDemand({productId: "p1", orderId: "o1"}))
    ->Demand.thenEvent(RecordDemandSlice.DemandRecorded({productId: "p1", orderId: "o1"}))
  )
})
