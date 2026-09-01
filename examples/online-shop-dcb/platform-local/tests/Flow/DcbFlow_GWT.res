// Cross-plugin flow GWT on the real Catalog + Ordering plugins. Lives in the
// platform package because it threads slices from BOTH plugins — plugin
// isolation keeps either plugin from importing the other's source, but the
// platform composes both, and the boundary steps cross between them exactly as
// the in-memory bus routes commands in production.
//
//   Catalog: AddProduct ─→ ProductAdded
//     └─[Products_ExtensionPoint]→ ProductBecameAvailable
//          └─[Ordering Products_Extension]→ SyncNewProduct
//               └─ Ordering: SyncCatalogProduct ─→ CatalogProductSynced
//   Ordering: RegisterCustomer ─→ CustomerRegistered
//   Ordering: PlaceOrder ─→ OrderPlaced            ← succeeds only via the sync
//     └─ AutoShipOrder reacts → ShipOrder ─→ OrderShipped
//          └─ SendOrderConfirmation : confirmation effect fired
@@reventless.gwt

// Compose the automation onto a flat slice — the production split keeps
// collect/resolve inside the per-source mapping; the GWT needs them together.
let testContext: Reventless.AutomationSlice.context = {
  environment: "test",
  platformName: "test",
  pluginName: "ordering",
  sliceName: "AutoShipOrder",
}

module AutoShipOrderSlice = {
  include OrderingPlugin.AutoShipOrder
  type consumedEvent = OrderingPlugin.AutoShipOrder_Automation.FromOrderingDcb.sourceEvent
  let consumedEventSchema = OrderingPlugin.AutoShipOrder_Automation.FromOrderingDcb.sourceEventSchema
  let collect = e => OrderingPlugin.AutoShipOrder_Automation.FromOrderingDcb.collect(e, ~sourceId="", testContext)
  let resolve = OrderingPlugin.AutoShipOrder_Automation.FromOrderingDcb.resolve
  let process = OrderingPlugin.AutoShipOrder_Automation.process
}

module ConfirmSlice = {
  include OrderingPlugin.SendOrderConfirmation
  let collect = OrderingPlugin.SendOrderConfirmation_Translation.collect
}

module Add = CommandStep(CatalogPlugin.AddProduct, CatalogPlugin.AddProduct_Behavior)
module ProductsEp = ExtensionPointStep(CatalogPlugin.Products_ExtensionPointMapping)
module ProductsExt = ExtensionStep(OrderingPlugin.Products_Extension.Mapping)
module Sync = CommandStep(OrderingPlugin.SyncCatalogProduct, OrderingPlugin.SyncCatalogProduct_Behavior)
module Register = CommandStep(OrderingPlugin.RegisterCustomer, OrderingPlugin.RegisterCustomer_Behavior)
module Place = CommandStep(OrderingPlugin.PlaceOrder, OrderingPlugin.PlaceOrder_Behavior)
module Auto = AutomationStep(AutoShipOrderSlice)
module Ship = CommandStep(OrderingPlugin.ShipOrder, OrderingPlugin.ShipOrder_Behavior)
module Confirm = OutboundStep(ConfirmSlice)

describe("DCB cross-plugin flow", () => {
  test("Catalog product → Ordering sync → register → place → auto-ship → confirm", () =>
    start
    ->Add.whenCommand(
      CatalogPlugin.AddProduct.AddProduct({
        productId: "p1",
        name: "Book",
        description: "A good book",
        price: 9.99,
      }),
    )
    ->Add.thenEvent(
      CatalogPlugin.AddProduct.ProductAdded({
        productId: "p1",
        name: "Book",
        description: "A good book",
        price: 9.99,
      }),
    )
    ->ProductsEp.whenPublishedThrough
    ->ProductsEp.thenPublicEvent(
      CatalogSpec.Products_ExtensionPoint.ProductBecameAvailable({
        productId: "p1",
        name: "Book",
        price: 9.99,
      }),
    )
    ->ProductsExt.whenExtensionReacts
    ->ProductsExt.thenIssuesCommand(
      OrderingPlugin.SyncCatalogProduct.SyncNewProduct({productId: "p1", name: "Book", price: 9.99}),
    )
    ->Sync.whenCommand(
      OrderingPlugin.SyncCatalogProduct.SyncNewProduct({productId: "p1", name: "Book", price: 9.99}),
    )
    ->Sync.thenEvent(
      OrderingPlugin.SyncCatalogProduct.CatalogProductSynced({
        productId: "p1",
        name: "Book",
        price: 9.99,
      }),
    )
    ->Register.whenCommand(
      OrderingPlugin.RegisterCustomer.RegisterCustomer({
        customerId: "c1",
        email: "alice@example.com",
        address: "1 Test St",
      }),
    )
    ->Register.thenEvent(
      OrderingPlugin.RegisterCustomer.CustomerRegistered({
        customerId: "c1",
        email: "alice@example.com",
        address: "1 Test St",
      }),
    )
    ->Place.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"]}),
    )
    ->Place.thenEvent(
      OrderingPlugin.PlaceOrder.OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1"]}),
    )
    ->Auto.whenReacts
    ->Auto.thenIssuesCommand(OrderingPlugin.AutoShipOrder.ShipOrder({orderId: "o1"}))
    ->Ship.whenCommand(OrderingPlugin.ShipOrder.ShipOrder({orderId: "o1"}))
    ->Ship.thenEvent(OrderingPlugin.ShipOrder.OrderShipped({orderId: "o1"}))
    ->Confirm.thenOutbound([
      ("o1", {OrderingPlugin.SendOrderConfirmation.orderId: "o1", customerId: "c1"}),
    ])
  )

  test("placing an order for an unsynced product is rejected", () =>
    start
    ->Place.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"]}),
    )
    ->Place.thenError(ProductsNotAvailable({missing: ["p1"]}))
  )
})
