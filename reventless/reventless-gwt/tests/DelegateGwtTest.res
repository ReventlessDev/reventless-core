// Worked examples for Delegate_GWT — the ExtensionPoint / Extension boundary
// primitive. Mirrors the hybrid example's cross-plugin seam:
//   * an ExtensionPoint mapping turns internal events into public EP events
//     (including one-to-many fan-out), exercised via `FromExtensionPoint`;
//   * an Extension delegate turns EP events into delegate commands, exercised
//     via `FromExtension`.
// See `docs/plans/done/gwt-flow-and-extension-test-kinds.md` Phase 1.

S.enableJson()

module EPM = ReventlessInfra.ExtensionPointMapping
module EM = ReventlessInfra.ExtensionMapping

// ---------------------------------------------------------------------------
// Catalog Products extension point + its internal Product delegate.
// ---------------------------------------------------------------------------

module ProductsEpSpec = {
  let name = "Catalog.Products"
  let moduleUrl = ""

  @schema
  type command = NoCommand

  @schema
  type event =
    | ProductBecameAvailable({productId: string, name: string, price: float})
    | ProductPriceChanged({productId: string, price: float})

  @schema
  type directive = NoDirective
}

module ProductDelegate = {
  module Id = Reventless.Id.StringPure
  let name = "Product"

  @schema
  type command = NoCommand

  @schema
  type event =
    | ProductAdded({productId: string, name: string, price: float})
    | ProductPriceChanged({productId: string, price: float})

  @schema
  type error = NoError

  let moduleUrl = ""
  let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAuthenticated
}

module ProductsEpMapping = {
  module ExtensionPoint = ProductsEpSpec
  module Delegate = ProductDelegate

  let moduleUrl = "test:DelegateGwtTest:ProductsEpMapping"

  let mapIncomingCommand = (_id, _command, _meta) => []

  let mapOutgoingEvent = Some(
    (_id, event: ProductDelegate.event, _meta, _queryEngine) =>
      switch event {
      | ProductAdded({productId, name, price}) => [
          EPM.PublishEvent(
            productId,
            ProductsEpSpec.ProductBecameAvailable({productId, name, price}),
          ),
        ]
      | ProductPriceChanged({productId, price}) => [
          EPM.PublishEvent(productId, ProductsEpSpec.ProductPriceChanged({productId, price})),
        ]
      },
  )
}

module ProductsEpGwt = Delegate_GWT.FromExtensionPoint(ProductsEpMapping)

ProductsEpGwt.describe("Products ExtensionPoint mapping (FromExtensionPoint)", () => {
  ProductsEpGwt.test("ProductAdded publishes ProductBecameAvailable", () =>
    ProductsEpGwt.whenDelegateEvent(
      ProductDelegate.ProductAdded({productId: "p1", name: "Book", price: 9.99}),
    )->ProductsEpGwt.thenPublishesEvent(
      "p1",
      ProductsEpSpec.ProductBecameAvailable({productId: "p1", name: "Book", price: 9.99}),
    )
  )

  ProductsEpGwt.test("ProductPriceChanged publishes ProductPriceChanged", () =>
    ProductsEpGwt.whenDelegateEvent(
      ProductDelegate.ProductPriceChanged({productId: "p1", price: 7.5}),
    )->ProductsEpGwt.thenPublishesEvent(
      "p1",
      ProductsEpSpec.ProductPriceChanged({productId: "p1", price: 7.5}),
    )
  )
})

// ---------------------------------------------------------------------------
// Ordering Orders extension point — array-decomposed (one-to-many) fan-out.
// ---------------------------------------------------------------------------

module OrdersEpSpec = {
  let name = "Ordering.Orders"
  let moduleUrl = ""

  @schema
  type command = NoCommand

  @schema
  type event =
    | ItemOrdered({productId: string, orderId: string, customerId: string})
    | ItemOrderCancelled({productId: string, orderId: string})

  @schema
  type directive = NoDirective
}

module OrderDelegate = {
  module Id = Reventless.Id.StringPure
  let name = "Order"

  @schema
  type command = NoCommand

  @schema
  type event =
    | OrderPlaced({orderId: string, customerId: string, productIds: array<string>})
    | OrderCancelled({orderId: string, productIds: array<string>})

  @schema
  type error = NoError

  let moduleUrl = ""
  let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAuthenticated
}

module OrdersEpMapping = {
  module ExtensionPoint = OrdersEpSpec
  module Delegate = OrderDelegate

  let moduleUrl = "test:DelegateGwtTest:OrdersEpMapping"

  let mapIncomingCommand = (_id, _command, _meta) => []

  let mapOutgoingEvent = Some(
    (_id, event: OrderDelegate.event, _meta, _queryEngine) =>
      switch event {
      | OrderPlaced({orderId, customerId, productIds}) =>
        productIds->Array.map(pid => EPM.PublishEvent(
          pid,
          OrdersEpSpec.ItemOrdered({productId: pid, orderId, customerId}),
        ))
      | OrderCancelled({orderId, productIds}) =>
        productIds->Array.map(pid => EPM.PublishEvent(
          pid,
          OrdersEpSpec.ItemOrderCancelled({productId: pid, orderId}),
        ))
      },
  )
}

module OrdersEpGwt = Delegate_GWT.FromExtensionPoint(OrdersEpMapping)

OrdersEpGwt.describe("Orders ExtensionPoint mapping — fan-out", () => {
  OrdersEpGwt.test("OrderPlaced fans out to one ItemOrdered per product", () =>
    OrdersEpGwt.whenDelegateEvent(
      OrderDelegate.OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1", "p2"]}),
    )->OrdersEpGwt.thenPublishesEvents([
      ("p1", OrdersEpSpec.ItemOrdered({productId: "p1", orderId: "o1", customerId: "c1"})),
      ("p2", OrdersEpSpec.ItemOrdered({productId: "p2", orderId: "o1", customerId: "c1"})),
    ])
  )

  OrdersEpGwt.test("OrderPlaced with no products publishes nothing", () =>
    OrdersEpGwt.whenDelegateEvent(
      OrderDelegate.OrderPlaced({orderId: "o2", customerId: "c1", productIds: []}),
    )->OrdersEpGwt.thenPublishesNothing
  )
})

// ---------------------------------------------------------------------------
// Ordering Products extension — delegates EP events to SyncCatalogProduct.
// ---------------------------------------------------------------------------

module SyncDelegate = {
  module Id = Reventless.Id.StringPure
  let name = "SyncCatalogProduct"

  @schema
  type command =
    | SyncNewProduct({productId: string, name: string, price: float})
    | ChangeSyncedPrice({productId: string, price: float})

  @schema
  type event = NoEvent

  @schema
  type error = NoError

  let moduleUrl = ""
  let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAuthenticated
}

module ProductsExtMapping = {
  module ExtensionPoint = ProductsEpSpec
  module Delegate = SyncDelegate

  let moduleUrl = ""
  let delegateModuleUrl = ""

  let mapIncomingEvent = (_id, event: ProductsEpSpec.event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ProductBecameAvailable({productId, name, price}) => [
        EM.PublishStateChangeSliceCommand(SyncDelegate.SyncNewProduct({productId, name, price})),
      ]
    | ProductPriceChanged({productId, price}) => [
        EM.PublishStateChangeSliceCommand(SyncDelegate.ChangeSyncedPrice({productId, price})),
      ]
    }

  let mapOutgoingEvent = None
}

module ProductsExtGwt = Delegate_GWT.FromExtension(ProductsExtMapping)

ProductsExtGwt.describe("Products Extension delegate (FromExtension)", () => {
  ProductsExtGwt.test("ProductBecameAvailable issues SyncNewProduct", () =>
    ProductsExtGwt.whenIncomingEvent(
      ProductsEpSpec.ProductBecameAvailable({productId: "p1", name: "Book", price: 9.99}),
    )->ProductsExtGwt.thenPublishesCommand(
      SyncDelegate.SyncNewProduct({productId: "p1", name: "Book", price: 9.99}),
    )
  )

  ProductsExtGwt.test("ProductPriceChanged issues ChangeSyncedPrice", () =>
    ProductsExtGwt.whenIncomingEvent(
      ProductsEpSpec.ProductPriceChanged({productId: "p1", price: 7.5}),
    )->ProductsExtGwt.thenPublishesCommand(
      SyncDelegate.ChangeSyncedPrice({productId: "p1", price: 7.5}),
    )
  )
})

// ---------------------------------------------------------------------------
// EP `mapIncomingCommand` — an incoming protocol command routed to the wrapped
// aggregate (the other EP direction: `whenIncomingCommand`).
// ---------------------------------------------------------------------------

module InventoryEpSpec = {
  let name = "Catalog.Inventory"
  let moduleUrl = ""

  @schema
  type command = Restock({sku: string, qty: int})

  @schema
  type event = NoEvent

  @schema
  type directive = NoDirective
}

module StockDelegate = {
  module Id = Reventless.Id.StringPure
  let name = "Stock"

  @schema
  type command = Restock({sku: string, qty: int})

  @schema
  type event = NoEvent

  @schema
  type error = NoError

  let moduleUrl = ""
  let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAuthenticated
}

module InventoryEpMapping = {
  module ExtensionPoint = InventoryEpSpec
  module Delegate = StockDelegate

  let moduleUrl = "test:DelegateGwtTest:InventoryEpMapping"

  let mapIncomingCommand = (id, command: InventoryEpSpec.command, _meta) =>
    switch command {
    | Restock({sku, qty}) => [EPM.PublishCommand(id, StockDelegate.Restock({sku, qty}))]
    }

  let mapOutgoingEvent = None
}

module InventoryEpGwt = Delegate_GWT.FromExtensionPoint(InventoryEpMapping)

InventoryEpGwt.describe("Inventory ExtensionPoint mapping — incoming command", () => {
  InventoryEpGwt.test("Restock protocol command routes to the Stock delegate", () =>
    InventoryEpGwt.whenIncomingCommand(
      InventoryEpSpec.Restock({sku: "s1", qty: 5}),
    )->InventoryEpGwt.thenPublishesCommand("gwt-id", StockDelegate.Restock({sku: "s1", qty: 5}))
  )
})

// ---------------------------------------------------------------------------
// Extension `mapOutgoingEvent` — an internal delegate event published back as a
// protocol command (the other Extension direction: `whenDelegateEvent`).
// ---------------------------------------------------------------------------

module FeedbackEpSpec = {
  let name = "Ordering.Feedback"
  let moduleUrl = ""

  @schema
  type command = AckProduct({productId: string})

  @schema
  type event = NoEvent

  @schema
  type directive = NoDirective
}

module SyncedDelegate = {
  module Id = Reventless.Id.StringPure
  let name = "SyncedProduct"

  @schema
  type command = NoCommand

  @schema
  type event = ProductSynced({productId: string})

  @schema
  type error = NoError

  let moduleUrl = ""
  let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAuthenticated
}

module FeedbackExtMapping = {
  module ExtensionPoint = FeedbackEpSpec
  module Delegate = SyncedDelegate

  let moduleUrl = ""
  let delegateModuleUrl = ""

  let mapIncomingEvent = (_id, event: FeedbackEpSpec.event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | NoEvent => []
    }

  let mapOutgoingEvent = Some(
    (id, event: SyncedDelegate.event, _meta, _pluginDef) =>
      switch event {
      | ProductSynced({productId}) => [
          EM.PublishExtensionPointCommand(id, FeedbackEpSpec.AckProduct({productId: productId})),
        ]
      },
  )
}

module FeedbackExtGwt = Delegate_GWT.FromExtension(FeedbackExtMapping)

FeedbackExtGwt.describe("Feedback Extension delegate — outgoing command", () => {
  FeedbackExtGwt.test("ProductSynced publishes the AckProduct protocol command", () =>
    FeedbackExtGwt.whenDelegateEvent(
      SyncedDelegate.ProductSynced({productId: "p1"}),
    )->FeedbackExtGwt.thenPublishesExtensionPointCommand(
      "gwt-id",
      FeedbackEpSpec.AckProduct({productId: "p1"}),
    )
  )
})

// ---------------------------------------------------------------------------
// Directives — a `HandleDirective` action carries a typed directive on its own
// channel: asserted via `thenHandlesDirective`, disjoint from published events
// (an arm can do both), and `thenHandlesNoDirective` confirms an arm raises none.
// ---------------------------------------------------------------------------

module NotifyEpSpec = {
  let name = "Catalog.Notify"
  let moduleUrl = ""

  @schema
  type command = NoCommand

  @schema
  type event = Pinged({productId: string})

  @schema
  type directive =
    | NotifyOps({channel: string})
    | FlushCache
}

module NotifyEpMapping = {
  module ExtensionPoint = NotifyEpSpec
  module Delegate = ProductDelegate

  let moduleUrl = "test:DelegateGwtTest:NotifyEpMapping"

  let handleDirective: EPM.directiveHandler<NotifyEpSpec.directive> = (_c, _d, _q, _dir) =>
    Promise.resolve()

  let mapIncomingCommand = (_id, _command, _meta) => []

  // ProductAdded both PUBLISHES an event and HANDLES a directive; ProductPriceChanged
  // publishes only — so `thenHandlesNoDirective` holds for it.
  let mapOutgoingEvent = Some(
    (_id, event: ProductDelegate.event, _meta, _queryEngine) =>
      switch event {
      | ProductAdded({productId}) => [
          EPM.PublishEvent(productId, NotifyEpSpec.Pinged({productId: productId})),
          EPM.HandleDirective(handleDirective, NotifyEpSpec.NotifyOps({channel: "ops"})),
        ]
      | ProductPriceChanged({productId}) => [
          EPM.PublishEvent(productId, NotifyEpSpec.Pinged({productId: productId})),
        ]
      },
  )
}

module NotifyEpGwt = Delegate_GWT.FromExtensionPoint(NotifyEpMapping)

NotifyEpGwt.describe("Notify ExtensionPoint mapping — directives", () => {
  NotifyEpGwt.test("ProductAdded handles the NotifyOps directive", () =>
    NotifyEpGwt.whenDelegateEvent(
      ProductDelegate.ProductAdded({productId: "p1", name: "Book", price: 9.99}),
    )->NotifyEpGwt.thenHandlesDirective(NotifyEpSpec.NotifyOps({channel: "ops"}))
  )

  // The directive does NOT leak into the published-event channel.
  NotifyEpGwt.test("ProductAdded still publishes only the Pinged event", () =>
    NotifyEpGwt.whenDelegateEvent(
      ProductDelegate.ProductAdded({productId: "p1", name: "Book", price: 9.99}),
    )->NotifyEpGwt.thenPublishesEvent("p1", NotifyEpSpec.Pinged({productId: "p1"}))
  )

  NotifyEpGwt.test("ProductPriceChanged raises no directive", () =>
    NotifyEpGwt.whenDelegateEvent(
      ProductDelegate.ProductPriceChanged({productId: "p1", price: 7.5}),
    )->NotifyEpGwt.thenHandlesNoDirective
  )
})

module NotifyExtMapping = {
  module ExtensionPoint = NotifyEpSpec
  module Delegate = SyncDelegate

  let moduleUrl = ""
  let delegateModuleUrl = ""

  // An Extension directive handler is a bare `Reventless.Handler.handler` (no
  // Schedule/QueryEngine args — extensions are user code).
  let handleDirective: Reventless.Handler.handler<NotifyEpSpec.directive> = _dir =>
    Promise.resolve()

  let mapIncomingEvent = (_id, event: NotifyEpSpec.event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Pinged({productId}) => [
        EM.PublishStateChangeSliceCommand(SyncDelegate.ChangeSyncedPrice({productId, price: 0.0})),
        EM.HandleDirective(handleDirective, NotifyEpSpec.FlushCache),
      ]
    }

  let mapOutgoingEvent = None
}

module NotifyExtGwt = Delegate_GWT.FromExtension(NotifyExtMapping)

NotifyExtGwt.describe("Notify Extension delegate — directives", () => {
  NotifyExtGwt.test("Pinged handles the FlushCache directive", () =>
    NotifyExtGwt.whenIncomingEvent(
      NotifyEpSpec.Pinged({productId: "p1"}),
    )->NotifyExtGwt.thenHandlesDirective(NotifyEpSpec.FlushCache)
  )

  NotifyExtGwt.test("Pinged still publishes only the ChangeSyncedPrice command", () =>
    NotifyExtGwt.whenIncomingEvent(
      NotifyEpSpec.Pinged({productId: "p1"}),
    )->NotifyExtGwt.thenPublishesCommand(
      SyncDelegate.ChangeSyncedPrice({productId: "p1", price: 0.0}),
    )
  )
})
