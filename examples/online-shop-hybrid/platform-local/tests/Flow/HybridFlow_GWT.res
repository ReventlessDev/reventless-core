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

module Cat = DecisionStep(CatalogPlugin.AddCategory, CatalogPlugin.AddCategory_Decision)
module Add = DecisionStep(CatalogPlugin.AddProduct, CatalogPlugin.AddProduct_Decision)
module Archive = DecisionStep(CatalogPlugin.ArchiveProduct, CatalogPlugin.ArchiveProduct_Decision)
module Unarchive = DecisionStep(
  CatalogPlugin.UnarchiveProduct,
  CatalogPlugin.UnarchiveProduct_Decision,
)
module ProductsEp = ExtensionPointStep(CatalogPlugin.Products_ExtensionPointMapping)
module ProductsExt = ExtensionStep(OrderingPlugin.Products_Extension.Mapping)
module Sync = DecisionStep(
  OrderingPlugin.SyncCatalogProduct,
  OrderingPlugin.SyncCatalogProduct_Decision,
)
module Place = DecisionStep(OrderingPlugin.PlaceOrder, OrderingPlugin.PlaceOrder_Decision)
module OrdersEp = ExtensionPointStep(OrderingPlugin.Orders_ExtensionPointMapping)
module OrdersExt = ExtensionStep(CatalogPlugin.Orders_Extension.Mapping)
module Demand = DecisionStep(
  CatalogPlugin.RecordProductDemand,
  CatalogPlugin.RecordProductDemand_Decision,
)

describe("Hybrid cross-plugin flow", () => {
  // scenario-id: fb61d285-6b0f-47ac-9967-c5e060794865
  test("Tier 2 — a product added in Catalog becomes orderable in Ordering via the sync", () =>
    start
    // AddProduct now verifies the category exists, so seed it into the shared log first.
    ->Cat.givenEvents([CatalogPlugin.AddCategory.CategoryAdded({categoryId: cat1, name: "Books"})])
    ->Add.whenCommand(
      CatalogPlugin.AddProduct.AddProduct({
        productId: p1,
        name: book,
        description: bookDescription,
        price: bookPrice,
        categoryId: cat1,
      }),
    )
    ->Add.thenEvent(
      CatalogPlugin.AddProduct.ProductAdded({
        productId: p1,
        name: book,
        description: bookDescription,
        price: bookPrice,
        categoryId: cat1,
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
    ->Place.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 2}],
        shippingMethod: Standard,
      }),
    )
    ->Place.thenEvent(
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
    ->Place.whenCommand(
      OrderingPlugin.PlaceOrder.PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->Place.thenError(ProductsNotAvailable({missing: [p1]}))
  )

  // The withdrawal round trip across the boundary: an archived product cannot be
  // ordered, and unarchiving it makes it orderable again.
  // scenario-id: 46034b40-be5c-4934-86e2-da5bcefe78b7
  test(
    "Tier 2 — archiving a product withdraws it from ordering, and unarchiving relists it",
    () =>
      start
      ->Add.givenEvents([
        CatalogPlugin.AddProduct.ProductAdded({
          productId: p1,
          name: book,
          description: bookDescription,
          price: bookPrice,
          categoryId: cat1,
        }),
      ])
      ->Sync.givenEvents([
        OrderingPlugin.SyncCatalogProduct.CatalogProductSynced({
          productId: p1,
          name: book,
          price: bookPrice,
        }),
      ])
      ->Archive.whenCommand(CatalogPlugin.ArchiveProduct.ArchiveProduct({productId: p1}))
      ->Archive.thenEvent(CatalogPlugin.ArchiveProduct.ProductArchived({productId: p1}))
      ->ProductsEp.whenPublished
      ->ProductsEp.thenPublicEvent(
        CatalogSpec.Products_ExtensionPoint.ProductWithdrawn({productId: p1}),
      )
      ->ProductsExt.whenReacts
      ->ProductsExt.thenIssuesCommand(
        OrderingPlugin.SyncCatalogProduct.WithdrawSyncedProduct({productId: p1}),
      )
      ->Sync.whenCommand(OrderingPlugin.SyncCatalogProduct.WithdrawSyncedProduct({productId: p1}))
      ->Sync.thenEvent(OrderingPlugin.SyncCatalogProduct.CatalogProductWithdrawn({productId: p1}))
      ->Place.whenCommand(
        OrderingPlugin.PlaceOrder.PlaceOrder({
          orderId: o1,
          customerId: c1,
          lineItems: [{productId: p1, quantity: 1}],
          shippingMethod: Standard,
        }),
      )
      ->Place.thenError(ProductsNotAvailable({missing: [p1]}))
      ->Unarchive.whenCommand(CatalogPlugin.UnarchiveProduct.UnarchiveProduct({productId: p1}))
      ->Unarchive.thenEvent(CatalogPlugin.UnarchiveProduct.ProductUnarchived({productId: p1}))
      ->ProductsEp.whenPublished
      ->ProductsEp.thenPublicEvent(
        CatalogSpec.Products_ExtensionPoint.ProductRelisted({productId: p1}),
      )
      ->ProductsExt.whenReacts
      ->ProductsExt.thenIssuesCommand(
        OrderingPlugin.SyncCatalogProduct.RelistSyncedProduct({productId: p1}),
      )
      ->Sync.whenCommand(OrderingPlugin.SyncCatalogProduct.RelistSyncedProduct({productId: p1}))
      ->Sync.thenEvent(
        OrderingPlugin.SyncCatalogProduct.CatalogProductRelisted({
          productId: p1,
          name: book,
          price: bookPrice,
        }),
      )
      ->Place.whenCommand(
        OrderingPlugin.PlaceOrder.PlaceOrder({
          orderId: o1,
          customerId: c1,
          lineItems: [{productId: p1, quantity: 1}],
          shippingMethod: Standard,
        }),
      )
      ->Place.thenEvent(
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
      ->Sync.givenEvents([
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
      ->Place.whenCommand(
        OrderingPlugin.PlaceOrder.PlaceOrder({
          orderId: o1,
          customerId: c1,
          lineItems: [{productId: p1, quantity: 1}, {productId: p2, quantity: 3}],
          shippingMethod: Standard,
        }),
      )
      ->Place.thenEvent(
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
      ->OrdersEp.whenPublished
      ->OrdersEp.thenPublicEvents([
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
      ->OrdersExt.whenReacts
      ->OrdersExt.thenIssuesCommands([
        CatalogPlugin.RecordProductDemand.RecordDemand({productId: p1, orderId: "o1"}),
        CatalogPlugin.RecordProductDemand.RecordDemand({productId: p2, orderId: "o1"}),
      ])
      ->Demand.whenCommand(
        CatalogPlugin.RecordProductDemand.RecordDemand({productId: p1, orderId: "o1"}),
      )
      ->Demand.thenEvent(
        CatalogPlugin.RecordProductDemand.ProductDemandRecorded({
          productId: p1,
          orderId: "o1",
        }),
      ),
  )

  // The steps above name the slices a scenario walks through. These two name
  // every slice in each plugin, because the property is the boundary's and not
  // any slice's: one slice that cannot resolve its partition discards the
  // derived scope for all of them, and `AddProduct`'s category check silently
  // stops reading categories. Both plugins pass their own per-slice tests
  // throughout, which is why the assertion belongs here.
  // scenario-id: 9bc616d7-83a3-47c3-aa1d-3113656f16b8
  test("the Catalog boundary derives its DCB scope", () =>
    start->thenBoundaryScopeResolves(~name="Catalog", CatalogPlugin.Plugin.dcbSliceSchemas)
  )

  // scenario-id: fd69ab9b-c245-4bc8-a8fb-f677d63c91fd
  test("the Ordering boundary derives its DCB scope", () =>
    start->thenBoundaryScopeResolves(~name="Ordering", OrderingPlugin.Plugin.dcbSliceSchemas)
  )
})
