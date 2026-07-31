// Cross-slice flow GWT for the Ordering plugin: one declarative chain threads a
// single order through every tile of its Event Modeling lane —
//
//   PlaceOrder ─→ OrderPlaced
//     ├─ AutoShipOrder reacts → ShipOrder ─→ OrderShipped
//     ├─ Orders (view) : status Placed → Shipped
//     └─ SendOrderConfirmation : confirmation effect fired
//
// PlaceOrder only succeeds because the referenced product was synced first, so
// the flow seeds a CatalogProductSynced event before placing the order.
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
  include AutoShipOrder
  type consumedEvent = AutoShipOrder_Automation.FromOrderingDcb.sourceEvent
  let consumedEventSchema = AutoShipOrder_Automation.FromOrderingDcb.sourceEventSchema
  let collect = e => AutoShipOrder_Automation.FromOrderingDcb.collect(e, testContext)
  let resolve = AutoShipOrder_Automation.FromOrderingDcb.resolve
  let process = AutoShipOrder_Automation.process
}

module ConfirmSlice = {
  include SendOrderConfirmation
  let collect = SendOrderConfirmation_Translation.collect
}

module Sync = CommandStep(SyncCatalogProduct, SyncCatalogProduct_Behavior)
module Place = CommandStep(PlaceOrder, PlaceOrder_Behavior)
module Auto = AutomationStep(AutoShipOrderSlice)
module Ship = CommandStep(ShipOrder, ShipOrder_Behavior)
module OrdersView = ViewStep(Orders, Orders_Projection)
module Confirm = OutboundStep(ConfirmSlice)

// Prices are money now, so a test writes the amount a person would say and
// converts it once. `ofMajor` scales by the currency's own exponent, which is
// what keeps the literal honest: 9.99 EUR is 999 cents, and the same call on a
// JPY price would scale by 1.
let eur = amount => Reventless.Money.ofMajor(~amount, ~currency=EUR)

describe("Ordering flow — place → auto-ship → confirm", () => {
  test("an order is placed, auto-shipped, projected as Shipped, and confirmed", () =>
    start
    ->Sync.givenEvents([
      SyncCatalogProduct.CatalogProductSynced({productId: "p1", name: "Book", price: eur(9.99)}),
    ])
    // Express, so the automation picks it up — a Standard or Pickup order would
    // stop at Placed and wait for an explicit ShipOrder.
    ->Place.whenCommand(
      PlaceOrder.PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Express,
      }),
    )
    ->Place.thenEvent(
      PlaceOrder.OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Express,
      }),
    )
    ->Auto.whenReacts
    ->Auto.thenIssuesCommand(AutoShipOrder.ShipOrder({orderId: "o1"}))
    ->Ship.whenCommand(ShipOrder.ShipOrder({orderId: "o1"}))
    ->Ship.thenEvent(ShipOrder.OrderShipped({orderId: "o1"}))
    ->OrdersView.thenViewState(
      "o1",
      {
        Orders.orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        status: Shipped,
        shippingMethod: Express,
        placedAt: "time",
        shippedAt: "time",
      },
    )
    ->Confirm.thenOutbound([("o1", {SendOrderConfirmation.orderId: "o1", customerId: "c1"})])
  )

  test("placing an order for an unsynced product is rejected", () =>
    start
    ->Place.whenCommand(
      PlaceOrder.PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
      }),
    )
    ->Place.thenError(ProductsNotAvailable({missing: ["p1"]}))
  )
})
