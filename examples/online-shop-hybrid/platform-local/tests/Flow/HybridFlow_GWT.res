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

open PlatformLocal_Examples

module Catalog = CatalogPlugin.Flow
module Ordering = OrderingPlugin.Flow

describe("Hybrid cross-plugin flow", () => {
  // scenario-id: 248c2d39-f883-41e5-a4d7-e128489029f6
  test("Tier 2 — a product added in Catalog is synced into Ordering", () =>
    start
    // AddProduct now verifies the category exists, so seed it into the shared log first.
    ->Catalog.AddCategory.givenEvents([
      CatalogPlugin.AddCategory.CategoryAdded({categoryId: cat1, name: "Books"}),
    ])
    ->Catalog.AddProduct.whenCommand(
      CatalogPlugin.AddProduct.AddProduct({
        productId: p1,
        name: book,
        description: bookDescription,
        price: bookPrice,
        categoryId: cat1,
      }),
    )
    ->Catalog.AddProduct.thenEvent(
      CatalogPlugin.AddProduct.ProductAdded({
        productId: p1,
        name: book,
        description: bookDescription,
        price: bookPrice,
        categoryId: cat1,
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
    ->Ordering.SyncCatalogProduct.whenIssued
    ->Ordering.SyncCatalogProduct.thenEvent(
      OrderingPlugin.SyncCatalogProduct.CatalogProductSynced({
        productId: p1,
        name: book,
        price: bookPrice,
      }),
    )
  )

  // scenario-id: fb61d285-6b0f-47ac-9967-c5e060794865
  test("Tier 2 — a product added in Catalog becomes orderable in Ordering via the sync", () =>
    after("Tier 2 — a product added in Catalog is synced into Ordering")
    ->Ordering.PlaceOrder.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 2}],
        shippingMethod: Standard,
      }),
    )
    ->Ordering.PlaceOrder.thenEvent(
      OrderingPlugin.PlaceOrder.OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        // The price crossed the boundary with the name and the availability, so
        // the total is computed on the Ordering side with no read back into
        // Catalog — two of a EUR 9.99 book.
        lines: [twoBooksLine],
        total: twoBooksPrice,
        shippingMethod: Standard,
        // Recorded off the catalog's own sync, which is the point of this tier:
        // the name crossed the plugin boundary with the availability.
        firstProductName: book,
      }),
    )
  )

  // scenario-id: 9aa05b2a-960a-4fbf-938b-74114a4ce4ac
  test("Tier 2 — placing an order for an unsynced product is rejected", () =>
    start
    ->Ordering.PlaceOrder.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->Ordering.PlaceOrder.thenError(ProductsNotAvailable({missing: [p1]}))
  )

  // The withdrawal round trip across the boundary: an archived product cannot be
  // ordered, and unarchiving it makes it orderable again.
  // scenario-id: 46034b40-be5c-4934-86e2-da5bcefe78b7
  test(
    "Tier 2 — archiving a product withdraws it from ordering, and unarchiving relists it",
    () =>
      // The product as the sync left it, not typed in again.
      after("Tier 2 — a product added in Catalog is synced into Ordering")
      ->Catalog.ArchiveProduct.whenCommand(
        CatalogPlugin.ArchiveProduct.ArchiveProduct({productId: p1}),
      )
      ->Catalog.ArchiveProduct.thenEvent(
        CatalogPlugin.ArchiveProduct.ProductArchived({productId: p1}),
      )
      ->Catalog.Products_ExtensionPoint.whenPublished
      ->Catalog.Products_ExtensionPoint.thenPublicEvent(
        CatalogSpec.Products_ExtensionPoint.ProductWithdrawn({productId: p1}),
      )
      ->Ordering.Products_Extension.whenReacts
      ->Ordering.Products_Extension.thenIssuesCommand(
        OrderingPlugin.SyncCatalogProduct.WithdrawSyncedProduct({productId: p1}),
      )
      ->Ordering.SyncCatalogProduct.whenIssued
      ->Ordering.SyncCatalogProduct.thenEvent(
        OrderingPlugin.SyncCatalogProduct.CatalogProductWithdrawn({productId: p1}),
      )
      ->Ordering.PlaceOrder.whenCommand(
        OrderingPlugin.PlaceOrder.PlaceOrder({
          orderId: o1,
          customerId: c1,
          lineItems: [{productId: p1, quantity: 1}],
          shippingMethod: Standard,
        }),
      )
      ->Ordering.PlaceOrder.thenError(ProductsNotAvailable({missing: [p1]}))
      ->Catalog.UnarchiveProduct.whenCommand(
        CatalogPlugin.UnarchiveProduct.UnarchiveProduct({productId: p1}),
      )
      ->Catalog.UnarchiveProduct.thenEvent(
        CatalogPlugin.UnarchiveProduct.ProductUnarchived({productId: p1}),
      )
      ->Catalog.Products_ExtensionPoint.whenPublished
      ->Catalog.Products_ExtensionPoint.thenPublicEvent(
        CatalogSpec.Products_ExtensionPoint.ProductRelisted({productId: p1}),
      )
      ->Ordering.Products_Extension.whenReacts
      ->Ordering.Products_Extension.thenIssuesCommand(
        OrderingPlugin.SyncCatalogProduct.RelistSyncedProduct({productId: p1}),
      )
      ->Ordering.SyncCatalogProduct.whenIssued
      ->Ordering.SyncCatalogProduct.thenEvent(
        OrderingPlugin.SyncCatalogProduct.CatalogProductRelisted({
          productId: p1,
          name: book,
          price: bookPrice,
        }),
      )
      ->Ordering.PlaceOrder.whenCommand(
        OrderingPlugin.PlaceOrder.PlaceOrder({
          orderId: o1,
          customerId: c1,
          lineItems: [{productId: p1, quantity: 1}],
          shippingMethod: Standard,
        }),
      )
      ->Ordering.PlaceOrder.thenEvent(
        OrderingPlugin.PlaceOrder.OrderPlaced({
          orderId: o1,
          customerId: c1,
          productIds: [p1],
          lines: [oneBookLine],
          total: bookPrice,
          shippingMethod: Standard,
          firstProductName: book,
        }),
      ),
  )

  // scenario-id: 5b6dea26-5929-4dff-8431-287196239d1f
  test(
    "Tier 3 — a batch order fans out to one demand command per product, round-tripping into Catalog",
    () =>
      start
      ->Ordering.SyncCatalogProduct.givenEvents([
        OrderingPlugin.SyncCatalogProduct.CatalogProductSynced({
          productId: p1,
          name: book,
          price: bookPrice,
        }),
        OrderingPlugin.SyncCatalogProduct.CatalogProductSynced({
          productId: p2,
          name: pen,
          price: penPrice,
        }),
      ])
      ->Ordering.PlaceOrder.whenCommand(
        OrderingPlugin.PlaceOrder.PlaceOrder({
          orderId: o1,
          customerId: c1,
          lineItems: [{productId: p1, quantity: 1}, {productId: p2, quantity: 3}],
          shippingMethod: Standard,
        }),
      )
      ->Ordering.PlaceOrder.thenEvent(
        OrderingPlugin.PlaceOrder.OrderPlaced({
          orderId: o1,
          customerId: c1,
          productIds: [p1, p2],
          lines: [oneBookLine, threePensLine],
          total: bookAndThreePensPrice,
          shippingMethod: Standard,
          firstProductName: book,
        }),
      )
      // The placement is confirmed to the customer, as in Ordering's own flow.
      ->Ordering.NotificationIntake.whenReacts
      ->Ordering.NotificationIntake.thenIssuesCommand(
        OrderingPlugin.NotificationIntake.RequestNotification({
          recipientId: customerRef,
          category: OrderConfirmation,
          reference: confirmReference,
          subjectType: orderSubject,
          subjectRef: orderRef,
          subject: confirmationSubject,
          body: confirmationBody,
          sourceId: orderPlacedSource,
          origin: Default,
        }),
      )
      ->Ordering.Orders_ExtensionPoint.whenPublished
      ->Ordering.Orders_ExtensionPoint.thenPublicEvents([
        OrderingSpec.Orders_ExtensionPoint.ItemOrdered({
          productId: "p1",
          orderId: "o1",
          customerId: "c1",
        }),
        OrderingSpec.Orders_ExtensionPoint.ItemOrdered({
          productId: "p2",
          orderId: "o1",
          customerId: "c1",
        }),
      ])
      ->Catalog.Orders_Extension.whenReacts
      ->Catalog.Orders_Extension.thenIssuesCommands([
        CatalogPlugin.RecordProductDemand.RecordDemand({productId: p1, orderId: "o1"}),
        CatalogPlugin.RecordProductDemand.RecordDemand({productId: p2, orderId: "o1"}),
      ])
      // The fan-out is run whole: both lines' demand is recorded.
      ->Catalog.RecordProductDemand.whenIssued
      ->Catalog.RecordProductDemand.thenEvents([
        CatalogPlugin.RecordProductDemand.ProductDemandRecorded({productId: p1, orderId: "o1"}),
        CatalogPlugin.RecordProductDemand.ProductDemandRecorded({productId: p2, orderId: "o1"}),
      ])
      // Nothing else in either system reacts to this order.
      ->thenNothingElseReacts([Catalog.parts, Ordering.parts]),
  )
})
