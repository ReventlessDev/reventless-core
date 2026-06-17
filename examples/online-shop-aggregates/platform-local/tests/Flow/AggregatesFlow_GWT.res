// Cross-aggregate flow GWT on the real online-shop-aggregates ordering plugin.
// Threads two aggregate-style command steps through the shared log:
//
//   CatalogProduct (sync) ─→ CatalogProduct.Synced
//     └─→ Order.Place ─→ Order.Placed
//          └─→ Order.Ship ─→ Order.Shipped
//
// All three steps live in the OrderingPlugin (CatalogProduct is the synced
// shadow Ordering keeps). The SideEffect tail (Order_EmailNotification) is
// exercised in isolation by Order_EmailNotification_GWT — Flow_GWT does not
// thread SideEffects.

@@reventless.gwt

module Sync = AggregateCommandStep(
  OrderingPlugin.CatalogProduct,
  OrderingPlugin.CatalogProduct_Behavior,
)
module Place = AggregateCommandStep(OrderingPlugin.Order, OrderingPlugin.Order_Behavior)

describe("Aggregates ordering flow", () => {
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
