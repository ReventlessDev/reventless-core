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

open PlatformLocal_Examples

module Add = DecisionStep(CatalogPlugin.AddProduct, CatalogPlugin.AddProduct_Decision)
module ProductsEp = ExtensionPointStep(CatalogPlugin.Products_ExtensionPointMapping)
module ProductsExt = ExtensionStep(OrderingPlugin.Products_Extension.Mapping)
module Sync = DecisionStep(
  OrderingPlugin.SyncCatalogProduct,
  OrderingPlugin.SyncCatalogProduct_Decision,
)
module Register = DecisionStep(
  OrderingPlugin.RegisterCustomer,
  OrderingPlugin.RegisterCustomer_Decision,
)
module Place = DecisionStep(OrderingPlugin.PlaceOrder, OrderingPlugin.PlaceOrder_Decision)
module Auto = AutomationStep(OrderingPlugin.AutoShipOrder, OrderingPlugin.AutoShipOrder_Automation)
module Ship = DecisionStep(OrderingPlugin.ShipOrder, OrderingPlugin.ShipOrder_Decision)
module Confirm = OutboundStep(
  OrderingPlugin.SendOrderConfirmation,
  OrderingPlugin.SendOrderConfirmation_Translation,
)

describe("DCB cross-plugin flow", () => {
  // scenario-id: bc4ba8e3-3d3d-4ba9-b3ec-a0dfe07bdf4b
  test("Catalog product → Ordering sync → register → place → auto-ship → confirm", () =>
    start
    ->Add.whenCommand(
      CatalogPlugin.AddProduct.AddProduct({
        productId: p1,
        name: book,
        description: bookDescription,
        price: bookPrice,
      }),
    )
    ->Add.thenEvent(
      CatalogPlugin.AddProduct.ProductAdded({
        productId: p1,
        name: book,
        description: bookDescription,
        price: bookPrice,
      }),
    )
    ->ProductsEp.whenPublished
    ->ProductsEp.thenPublicEvent(
      CatalogSpec.Products_ExtensionPoint.ProductBecameAvailable({
        productId: p1,
        name: book,
        price: bookPrice,
      }),
    )
    ->ProductsExt.whenReacts
    ->ProductsExt.thenIssuesCommand(
      OrderingPlugin.SyncCatalogProduct.SyncNewProduct({
        productId: p1,
        name: book,
        price: bookPrice,
      }),
    )
    ->Sync.whenCommand(
      OrderingPlugin.SyncCatalogProduct.SyncNewProduct({
        productId: p1,
        name: book,
        price: bookPrice,
      }),
    )
    ->Sync.thenEvent(
      OrderingPlugin.SyncCatalogProduct.CatalogProductSynced({
        productId: p1,
        name: book,
        price: bookPrice,
      }),
    )
    ->Register.whenCommand(
      OrderingPlugin.RegisterCustomer.RegisterCustomer({
        customerId: c1,
        email: aliceEmail,
        address: testStreet,
      }),
    )
    ->Register.thenEvent(
      OrderingPlugin.RegisterCustomer.CustomerRegistered({
        customerId: c1,
        email: Value(aliceEmail),
        address: Value(testStreet),
      }),
    )
    ->Place.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
      }),
    )
    ->Place.thenEvent(
      OrderingPlugin.PlaceOrder.OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
      }),
    )
    ->Auto.whenReacts
    ->Auto.thenIssuesCommand(OrderingPlugin.AutoShipOrder.ShipOrder({orderId: o1}))
    ->Ship.whenCommand(OrderingPlugin.ShipOrder.ShipOrder({orderId: o1}))
    ->Ship.thenEvent(OrderingPlugin.ShipOrder.OrderShipped({orderId: o1}))
    ->Confirm.thenOutbound([
      ("o1", {OrderingPlugin.SendOrderConfirmation.orderId: o1, customerId: c1}),
    ])
  )

  // scenario-id: f6b53074-8d6a-431a-b223-25a06ffb41e6
  test("placing an order for an unsynced product is rejected", () =>
    start
    ->Place.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
      }),
    )
    ->Place.thenError(ProductsNotAvailable({missing: [p1]}))
  )
})
