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

module Catalog = CatalogPlugin.Flow
module Ordering = OrderingPlugin.Flow

describe("DCB cross-plugin flow", () => {
  // scenario-id: bc4ba8e3-3d3d-4ba9-b3ec-a0dfe07bdf4b
  test("Catalog product → Ordering sync → register → place → auto-ship → confirm", () =>
    start
    ->Catalog.AddProduct.whenCommand(
      CatalogPlugin.AddProduct.AddProduct({
        productId: p1,
        name: book,
        description: bookDescription,
        price: bookPrice,
      }),
    )
    ->Catalog.AddProduct.thenEvent(
      CatalogPlugin.AddProduct.ProductAdded({
        productId: p1,
        name: book,
        description: bookDescription,
        price: bookPrice,
      }),
    )
    ->Catalog.Products_ExtensionPoint.whenPublished
    ->Catalog.Products_ExtensionPoint.thenPublicEvent(
      CatalogSpec.Products_ExtensionPoint.ProductBecameAvailable({
        productId: p1,
        name: book,
        price: bookPrice,
      }),
    )
    ->Ordering.Products_Extension.whenReacts
    ->Ordering.Products_Extension.thenIssuesCommand(
      OrderingPlugin.SyncCatalogProduct.SyncNewProduct({
        productId: p1,
        name: book,
        price: bookPrice,
      }),
    )
    ->Ordering.SyncCatalogProduct.whenCommand(
      OrderingPlugin.SyncCatalogProduct.SyncNewProduct({
        productId: p1,
        name: book,
        price: bookPrice,
      }),
    )
    ->Ordering.SyncCatalogProduct.thenEvent(
      OrderingPlugin.SyncCatalogProduct.CatalogProductSynced({
        productId: p1,
        name: book,
        price: bookPrice,
      }),
    )
    ->Ordering.RegisterCustomer.whenCommand(
      OrderingPlugin.RegisterCustomer.RegisterCustomer({
        customerId: c1,
        email: aliceEmail,
        address: testStreet,
      }),
    )
    ->Ordering.RegisterCustomer.thenEvent(
      OrderingPlugin.RegisterCustomer.CustomerRegistered({
        customerId: c1,
        email: Value(aliceEmail),
        address: Value(testStreet),
      }),
    )
    ->Ordering.PlaceOrder.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
      }),
    )
    ->Ordering.PlaceOrder.thenEvent(
      OrderingPlugin.PlaceOrder.OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
      }),
    )
    ->Ordering.AutoShipOrder.whenReacts
    ->Ordering.AutoShipOrder.thenIssuesCommand(
      OrderingPlugin.AutoShipOrder.ShipOrder({orderId: o1}),
    )
    ->Ordering.ShipOrder.whenCommand(OrderingPlugin.ShipOrder.ShipOrder({orderId: o1}))
    ->Ordering.ShipOrder.thenEvent(OrderingPlugin.ShipOrder.OrderShipped({orderId: o1}))
    ->Ordering.SendOrderConfirmation.thenOutbound([
      ("o1", {OrderingPlugin.SendOrderConfirmation.orderId: o1, customerId: c1}),
    ])
  )

  // scenario-id: f6b53074-8d6a-431a-b223-25a06ffb41e6
  test("placing an order for an unsynced product is rejected", () =>
    start
    ->Ordering.PlaceOrder.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
      }),
    )
    ->Ordering.PlaceOrder.thenError(ProductsNotAvailable({missing: [p1]}))
  )
})
