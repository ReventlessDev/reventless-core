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

open PlatformLocalExamples

module Cat = CommandStep(CatalogPlugin.AddCategory, CatalogPlugin.AddCategory_Behavior)
module Add = CommandStep(CatalogPlugin.AddProduct, CatalogPlugin.AddProduct_Behavior)
module ProductsEp = ExtensionPointStep(CatalogPlugin.Products_ExtensionPointMapping)
module ProductsExt = ExtensionStep(OrderingPlugin.Products_Extension.Mapping)
module Sync = CommandStep(
  OrderingPlugin.SyncCatalogProduct,
  OrderingPlugin.SyncCatalogProduct_Behavior,
)
module Place = CommandStep(OrderingPlugin.PlaceOrder, OrderingPlugin.PlaceOrder_Behavior)
module OrdersEp = ExtensionPointStep(OrderingPlugin.Orders_ExtensionPointMapping)
module OrdersExt = ExtensionStep(CatalogPlugin.Orders_Extension.Mapping)
module Demand = CommandStep(
  CatalogPlugin.RecordProductDemand,
  CatalogPlugin.RecordProductDemand_Behavior,
)

// Prices are money, so a test writes the amount a person would say and converts
// it once. `ofMajor` scales by the currency's own exponent, which is what keeps
// the literal honest: 9.99 EUR is 999 cents, and the same call on a JPY price
// would scale by 1.

describe("Hybrid cross-plugin flow", () => {
  // scenario-id: fb61d285-6b0f-47ac-9967-c5e060794865
  test("Tier 2 — a product added in Catalog becomes orderable in Ordering via the sync", () =>
    start
    // AddProduct now verifies the category exists, so seed it into the shared log first.
    ->Cat.givenEvents([CatalogPlugin.AddCategory.CategoryAdded({categoryId: cat1, name: "Books"})])
    ->Add.whenCommand(
      CatalogPlugin.AddProduct.AddProduct({
        productId: p1,
        name: "Book",
        description: "A good book",
        price: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
        categoryId: cat1,
      }),
    )
    ->Add.thenEvent(
      CatalogPlugin.AddProduct.ProductAdded({
        productId: p1,
        name: "Book",
        description: "A good book",
        price: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
        categoryId: cat1,
      }),
    )
    ->ProductsEp.whenPublishedThrough
    ->ProductsEp.thenPublicEvent(
      CatalogSpec.Products_ExtensionPoint.ProductBecameAvailable({
        productId: p1,
        name: "Book",
        price: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
      }),
    )
    ->ProductsExt.whenExtensionReacts
    ->ProductsExt.thenIssuesCommand(
      OrderingPlugin.SyncCatalogProduct.SyncNewProduct({
        productId: p1,
        name: "Book",
        price: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
      }),
    )
    ->Sync.whenCommand(
      OrderingPlugin.SyncCatalogProduct.SyncNewProduct({
        productId: p1,
        name: "Book",
        price: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
      }),
    )
    ->Sync.thenEvent(
      OrderingPlugin.SyncCatalogProduct.CatalogProductSynced({
        productId: p1,
        name: "Book",
        price: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
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
        lines: [
          {
            productId: p1,
            name: "Book",
            quantity: 2,
            unitPrice: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
            lineTotal: Reventless.Money.make(~amount=1998.0, ~currency=Reventless.Currency.EUR),
          },
        ],
        total: Reventless.Money.make(~amount=1998.0, ~currency=Reventless.Currency.EUR),
        shippingMethod: Standard,
        // Recorded off the catalog's own sync, which is the point of this tier:
        // the name crossed the plugin boundary with the availability.
        firstProductName: "Book",
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

  // scenario-id: 5b6dea26-5929-4dff-8431-287196239d1f
  test(
    "Tier 3 — a batch order fans out to one demand command per product, round-tripping into Catalog",
    () =>
      start
      ->Sync.givenEvents([
        OrderingPlugin.SyncCatalogProduct.CatalogProductSynced({
          productId: p1,
          name: "Book",
          price: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
        }),
        OrderingPlugin.SyncCatalogProduct.CatalogProductSynced({
          productId: p2,
          name: "Pen",
          price: Reventless.Money.make(~amount=150.0, ~currency=Reventless.Currency.EUR),
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
          lines: [
            {
              productId: p1,
              name: "Book",
              quantity: 1,
              unitPrice: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
              lineTotal: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
            },
            {
              productId: p2,
              name: "Pen",
              quantity: 3,
              unitPrice: Reventless.Money.make(~amount=150.0, ~currency=Reventless.Currency.EUR),
              lineTotal: Reventless.Money.make(~amount=450.0, ~currency=Reventless.Currency.EUR),
            },
          ],
          total: Reventless.Money.make(~amount=1449.0, ~currency=Reventless.Currency.EUR),
          shippingMethod: Standard,
          firstProductName: "Book",
        }),
      )
      ->OrdersEp.whenPublishedThrough
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
      ->OrdersExt.whenExtensionReacts
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
