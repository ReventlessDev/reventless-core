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
    ProductsEpGwt.whenInboundEvent(
      ProductDelegate.ProductAdded({productId: "p1", name: "Book", price: 9.99}),
    )->ProductsEpGwt.thenPublishesEvent(
      "p1",
      ProductsEpSpec.ProductBecameAvailable({productId: "p1", name: "Book", price: 9.99}),
    )
  )

  ProductsEpGwt.test("ProductPriceChanged publishes ProductPriceChanged", () =>
    ProductsEpGwt.whenInboundEvent(
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

  let mapIncomingCommand = (_id, _command, _meta) => []

  let mapOutgoingEvent = Some(
    (_id, event: OrderDelegate.event, _meta, _queryEngine) =>
      switch event {
      | OrderPlaced({orderId, customerId, productIds}) =>
        productIds->Array.map(pid =>
          EPM.PublishEvent(
            pid,
            OrdersEpSpec.ItemOrdered({productId: pid, orderId, customerId}),
          )
        )
      | OrderCancelled({orderId, productIds}) =>
        productIds->Array.map(pid =>
          EPM.PublishEvent(pid, OrdersEpSpec.ItemOrderCancelled({productId: pid, orderId}))
        )
      },
  )
}

module OrdersEpGwt = Delegate_GWT.FromExtensionPoint(OrdersEpMapping)

OrdersEpGwt.describe("Orders ExtensionPoint mapping — fan-out", () => {
  OrdersEpGwt.test("OrderPlaced fans out to one ItemOrdered per product", () =>
    OrdersEpGwt.whenInboundEvent(
      OrderDelegate.OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1", "p2"]}),
    )->OrdersEpGwt.thenPublishesEvents([
      ("p1", OrdersEpSpec.ItemOrdered({productId: "p1", orderId: "o1", customerId: "c1"})),
      ("p2", OrdersEpSpec.ItemOrdered({productId: "p2", orderId: "o1", customerId: "c1"})),
    ])
  )

  OrdersEpGwt.test("OrderPlaced with no products publishes nothing", () =>
    OrdersEpGwt.whenInboundEvent(
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
    ProductsExtGwt.whenInboundEvent(
      ProductsEpSpec.ProductBecameAvailable({productId: "p1", name: "Book", price: 9.99}),
    )->ProductsExtGwt.thenPublishesCommand(
      SyncDelegate.SyncNewProduct({productId: "p1", name: "Book", price: 9.99}),
    )
  )

  ProductsExtGwt.test("ProductPriceChanged issues ChangeSyncedPrice", () =>
    ProductsExtGwt.whenInboundEvent(
      ProductsEpSpec.ProductPriceChanged({productId: "p1", price: 7.5}),
    )->ProductsExtGwt.thenPublishesCommand(
      SyncDelegate.ChangeSyncedPrice({productId: "p1", price: 7.5}),
    )
  )
})
