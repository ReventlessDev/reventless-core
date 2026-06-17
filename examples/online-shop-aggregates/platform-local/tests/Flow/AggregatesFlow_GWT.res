// Cross-aggregate and cross-plugin flow GWT on the real online-shop-aggregates
// catalog + ordering plugins. Threads several aggregate-style command steps
// through one shared log:
//
//   Within Ordering:
//     CatalogProduct (sync) ─→ Order.Place ─→ Order.Ship
//
//   Cross-plugin (Catalog → Ordering → Catalog):
//     Catalog.Product.Add ─→ ProductAdded
//       └─[Products_ExtensionPoint]→ ProductBecameAvailable
//            └─[Ordering Products_Extension]→ Sync
//                 └─→ Ordering.CatalogProduct.Sync ─→ Synced
//                      └─→ Ordering.Order.Place ─→ Placed
//                           └─[Orders_ExtensionPoint, fan-out]→ ItemOrdered ×N
//                                └─[Catalog Orders_Extension]→ Record
//                                     └─→ Catalog.ProductDemand.Record ─→ Recorded
//
// The SideEffect tail (Order_EmailNotification) is exercised in isolation by
// Order_EmailNotification_GWT — Flow_GWT does not thread SideEffects.

@@reventless.gwt

// Single-plugin steps inside Ordering ----------------------------------------

module Sync = AggregateCommandStep(
  OrderingPlugin.CatalogProduct,
  OrderingPlugin.CatalogProduct_Behavior,
)
module Place = AggregateCommandStep(OrderingPlugin.Order, OrderingPlugin.Order_Behavior)

// Cross-plugin steps --------------------------------------------------------

module Add = AggregateCommandStep(CatalogPlugin.Product, CatalogPlugin.Product_Behavior)
module ProductsEp = ExtensionPointStep(CatalogPlugin.Products_ExtensionPointMapping)
module ProductsExt = ExtensionStep(OrderingPlugin.Products_Extension.Mapping)

module OrdersEp = ExtensionPointStep(OrderingPlugin.Orders_ExtensionPointMapping)
module OrdersExt = ExtensionStep(CatalogPlugin.Orders_Extension.Mapping)
module Demand = AggregateCommandStep(CatalogPlugin.ProductDemand, CatalogPlugin.ProductDemand_Behavior)

// Flows ---------------------------------------------------------------------

describe("Aggregates ordering flow (single plugin)", () => {
  test("sync product → place order → ship order", () =>
    start
    ->Sync.whenCommand(~id="p1", Sync({name: "Book", price: 9.99}))
    ->Sync.thenEvent(Synced({name: "Book", price: 9.99}))
    ->Place.whenCommand(~id="o1", Place({customerId: "c1", productIds: ["p1"]}))
    ->Place.thenEvent(Placed({customerId: "c1", productIds: ["p1"]}))
    ->Place.whenCommand(~id="o1", Ship)
    ->Place.thenEvent(Shipped)
  )

  test("re-placing the same order returns OrderAlreadyPlaced", () =>
    start
    ->Place.whenCommand(~id="o1", Place({customerId: "c1", productIds: ["p1"]}))
    ->Place.whenCommand(~id="o1", Place({customerId: "c1", productIds: ["p1"]}))
    ->Place.thenError(OrderAlreadyPlaced)
  )

  test("ship-before-place returns OrderNotFound", () =>
    start
    ->Place.whenCommand(~id="o1", Ship)
    ->Place.thenError(OrderNotFound)
  )

  test("a second order is not blocked by the first (~id isolation)", () =>
    start
    ->Place.whenCommand(~id="o1", Place({customerId: "c1", productIds: ["p1"]}))
    ->Place.thenEvent(Placed({customerId: "c1", productIds: ["p1"]}))
    ->Place.whenCommand(~id="o2", Place({customerId: "c2", productIds: ["p2"]}))
    ->Place.thenEvent(Placed({customerId: "c2", productIds: ["p2"]}))
  )

  test("givenEvents seeds an order's prior history", () =>
    start
    ->Place.givenEvents(~id="o1", [Placed({customerId: "c1", productIds: ["p1"]})])
    ->Place.whenCommand(~id="o1", Ship)
    ->Place.thenEvent(Shipped)
  )
})

describe("Aggregates cross-plugin flow", () => {
  test("Catalog.Add → EP → Ordering.Sync surfaces the product as ordering shadow", () =>
    start
    ->Add.whenCommand(~id="p1", Add({name: "Book", description: "A good book", price: 9.99}))
    ->Add.thenEvent(Added({name: "Book", description: "A good book", price: 9.99}))
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
      OrderingPlugin.CatalogProduct.Sync({name: "Book", price: 9.99}),
    )
    ->Sync.whenCommand(~id="p1", Sync({name: "Book", price: 9.99}))
    ->Sync.thenEvent(Synced({name: "Book", price: 9.99}))
  )

  test("Order.Place fans out to one ItemOrdered per product, round-tripping into Catalog", () =>
    start
    ->Place.whenCommand(~id="o1", Place({customerId: "c1", productIds: ["p1", "p2"]}))
    ->Place.thenEvent(Placed({customerId: "c1", productIds: ["p1", "p2"]}))
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
      CatalogPlugin.ProductDemand.Record({orderId: "o1"}),
      CatalogPlugin.ProductDemand.Record({orderId: "o1"}),
    ])
    ->Demand.whenCommand(~id="p1", Record({orderId: "o1"}))
    ->Demand.thenEvent(Recorded({orderId: "o1"}))
  )
})
