// Cross-plugin flow GWT on the real Catalog + Ordering plugins. This lives in
// the platform package because it threads slices from BOTH plugins — plugin
// isolation keeps either plugin from importing the other's source, but the
// platform composes both, and the boundary steps cross between them exactly as
// the in-memory bus routes commands in production.
//
//   Catalog: AddProduct ─→ ProductAdded
//     └─[Products_ExtensionPoint]→ ProductBecameAvailable
//          └─[Ordering Products_Extension]→ SyncNewProduct
//               └─ Ordering: SyncCatalogProduct ─→ CatalogProductSynced
//   Ordering: PlaceOrder ─→ OrderPlaced            ← succeeds only via the sync
//     └─[Orders_ExtensionPoint, fan-out]→ ItemOrdered ×N
//          └─[Catalog Orders_Extension]→ RecordDemand ×N
//               └─ Catalog: RecordProductDemand ─→ ProductDemandRecorded
@@reventless.gwt

module Cat = CommandStep(CatalogPlugin.AddCategory, CatalogPlugin.AddCategory_Behavior)
module Add = CommandStep(CatalogPlugin.AddProduct, CatalogPlugin.AddProduct_Behavior)
module ProductsEp = ExtensionPointStep(CatalogPlugin.Products_ExtensionPointMapping)
module ProductsExt = ExtensionStep(OrderingPlugin.Products_Extension.Mapping)
module Sync = CommandStep(OrderingPlugin.SyncCatalogProduct, OrderingPlugin.SyncCatalogProduct_Behavior)
module Place = CommandStep(OrderingPlugin.PlaceOrder, OrderingPlugin.PlaceOrder_Behavior)
module OrdersEp = ExtensionPointStep(OrderingPlugin.Orders_ExtensionPointMapping)
module OrdersExt = ExtensionStep(CatalogPlugin.Orders_Extension.Mapping)
module Demand = CommandStep(CatalogPlugin.RecordProductDemand, CatalogPlugin.RecordProductDemand_Behavior)

describe("Hybrid cross-plugin flow", () => {
  test("Tier 2 — a product added in Catalog becomes orderable in Ordering via the sync", () =>
    start
    // AddProduct now verifies the category exists, so seed it into the shared log first.
    ->Cat.givenEvents([CatalogPlugin.AddCategory.CategoryAdded({categoryId: "cat1", name: "Books"})])
    ->Add.whenCommand(
      CatalogPlugin.AddProduct.AddProduct({
        productId: "p1",
        name: "Book",
        description: "A good book",
        price: 9.99,
        categoryId: "cat1",
      }),
    )
    ->Add.thenEvent(
      CatalogPlugin.AddProduct.ProductAdded({
        productId: "p1",
        name: "Book",
        description: "A good book",
        price: 9.99,
        categoryId: "cat1",
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
    ->Place.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
      }),
    )
    ->Place.thenEvent(
      OrderingPlugin.PlaceOrder.OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
      }),
    )
  )

  test("Tier 2 — placing an order for an unsynced product is rejected", () =>
    start
    ->Place.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
      }),
    )
    ->Place.thenError(ProductsNotAvailable({missing: ["p1"]}))
  )

  test("Tier 3 — a batch order fans out to one demand command per product, round-tripping into Catalog", () =>
    start
    ->Sync.givenEvents([
      OrderingPlugin.SyncCatalogProduct.CatalogProductSynced({
        productId: "p1",
        name: "Book",
        price: 9.99,
      }),
      OrderingPlugin.SyncCatalogProduct.CatalogProductSynced({
        productId: "p2",
        name: "Pen",
        price: 1.5,
      }),
    ])
    ->Place.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1", "p2"],
        shippingMethod: Standard,
      }),
    )
    ->Place.thenEvent(
      OrderingPlugin.PlaceOrder.OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1", "p2"],
        shippingMethod: Standard,
      }),
    )
    ->OrdersEp.whenPublishedThrough
    ->OrdersEp.thenPublicEvents([
      OrderingSpec.Orders_ExtensionPoint.ItemOrdered({productId: "p1", orderId: "o1", customerId: "c1"}),
      OrderingSpec.Orders_ExtensionPoint.ItemOrdered({productId: "p2", orderId: "o1", customerId: "c1"}),
    ])
    ->OrdersExt.whenExtensionReacts
    ->OrdersExt.thenIssuesCommands([
      CatalogPlugin.RecordProductDemand.RecordDemand({productId: "p1", orderId: "o1"}),
      CatalogPlugin.RecordProductDemand.RecordDemand({productId: "p2", orderId: "o1"}),
    ])
    ->Demand.whenCommand(CatalogPlugin.RecordProductDemand.RecordDemand({productId: "p1", orderId: "o1"}))
    ->Demand.thenEvent(
      CatalogPlugin.RecordProductDemand.ProductDemandRecorded({productId: "p1", orderId: "o1"}),
    )
  )
})
