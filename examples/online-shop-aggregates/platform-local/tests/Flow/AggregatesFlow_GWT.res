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

// Ids are typed; the literals are made once, in the examples file beside this one.
open PlatformLocal_Examples

module Catalog = CatalogPlugin.Flow
module Ordering = OrderingPlugin.Flow

// Flows ---------------------------------------------------------------------

describe("Aggregates ordering flow (single plugin)", () => {
  // scenario-id: d92cb603-8688-401c-a54f-8d877410a6cf
  test("sync product → place order → ship order", () =>
    start
    ->Ordering.CatalogProduct.whenCommand(~id="p1", Sync({name: book, price: bookPrice}))
    ->Ordering.CatalogProduct.thenEvent(Synced({name: book, price: bookPrice}))
    ->Ordering.Order.whenCommand(~id="o1", Place({customerId: c1, productIds: [p1]}))
    ->Ordering.Order.thenEvent(Placed({customerId: c1, productIds: [p1]}))
    ->Ordering.Order.whenCommand(~id="o1", Ship)
    ->Ordering.Order.thenEvent(Shipped)
  )

  // scenario-id: 7e738dad-a991-4453-bf69-be8f3a900a23
  test("re-placing the same order returns OrderAlreadyPlaced", () =>
    start
    ->Ordering.Order.whenCommand(~id="o1", Place({customerId: c1, productIds: [p1]}))
    ->Ordering.Order.whenCommand(~id="o1", Place({customerId: c1, productIds: [p1]}))
    ->Ordering.Order.thenError(OrderAlreadyPlaced)
  )

  // scenario-id: 4892a92d-a6fb-46e1-b351-9e8997e08136
  test("ship-before-place returns OrderNotFound", () =>
    start
    ->Ordering.Order.whenCommand(~id="o1", Ship)
    ->Ordering.Order.thenError(OrderNotFound)
  )

  // scenario-id: d36e496f-a769-484e-ae97-9662c89d9d57
  test("a second order is not blocked by the first (~id isolation)", () =>
    start
    ->Ordering.Order.whenCommand(~id="o1", Place({customerId: c1, productIds: [p1]}))
    ->Ordering.Order.thenEvent(Placed({customerId: c1, productIds: [p1]}))
    ->Ordering.Order.whenCommand(~id="o2", Place({customerId: c2, productIds: [p2]}))
    ->Ordering.Order.thenEvent(Placed({customerId: c2, productIds: [p2]}))
  )

  // scenario-id: 8920746e-5d0b-4a80-b806-bdc846e7fd48
  test("givenEvents seeds an order's prior history", () =>
    start
    ->Ordering.Order.givenEvents(~id="o1", [Placed({customerId: c1, productIds: [p1]})])
    ->Ordering.Order.whenCommand(~id="o1", Ship)
    ->Ordering.Order.thenEvent(Shipped)
  )
})

describe("Aggregates cross-plugin flow", () => {
  // scenario-id: 1becac37-b590-4aed-b96f-1edc828afbb5
  test("Catalog.Add → EP → Ordering.Sync surfaces the product as ordering shadow", () =>
    start
    ->Catalog.Product.whenCommand(
      ~id="p1",
      Add({
        name: book,
        description: bookDescription,
        price: bookPrice,
        imageUrl: bookImage,
      }),
    )
    ->Catalog.Product.thenEvent(
      Added({
        name: book,
        description: bookDescription,
        price: bookPrice,
        imageUrl: bookImage,
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
      OrderingPlugin.CatalogProduct.Sync({name: book, price: bookPrice}),
    )
    ->Ordering.CatalogProduct.whenCommand(~id="p1", Sync({name: book, price: bookPrice}))
    ->Ordering.CatalogProduct.thenEvent(Synced({name: book, price: bookPrice}))
  )

  // scenario-id: 3a17540f-034e-47d6-8807-bbd7602f2c62
  test("Order.Place fans out to one ItemOrdered per product, round-tripping into Catalog", () =>
    start
    ->Ordering.Order.whenCommand(~id="o1", Place({customerId: c1, productIds: [p1, p2]}))
    ->Ordering.Order.thenEvent(Placed({customerId: c1, productIds: [p1, p2]}))
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
      CatalogPlugin.ProductDemand.Record({orderId: "o1"}),
      CatalogPlugin.ProductDemand.Record({orderId: "o1"}),
    ])
    ->Catalog.ProductDemand.whenCommand(~id="p1", Record({orderId: "o1"}))
    ->Catalog.ProductDemand.thenEvent(Recorded({orderId: "o1"}))
  )
})
