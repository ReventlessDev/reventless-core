// Cross-slice flow GWT for the Ordering plugin: one declarative chain threads a
// single order through every tile of its Event Modeling lane —
//
//   PlaceOrder ─→ OrderPlaced
//     ├─ AutoShipOrder reacts → ShipOrder ─→ OrderShipped
//     ├─ Orders (view) : status Placed → Shipped
//     └─ NotificationIntake reacts → RequestNotification ×2
//          (OrderConfirmation for the placement, ShippingUpdate for the shipment)
//
// The order lane ends where the notification competency begins. What happens to
// the request — which channels it goes out on, or why it does not — is decided
// against a recipient's own directory row, and belongs to that chapter's flow
// rather than this one.
//
// PlaceOrder only succeeds because the referenced product was synced first, so
// the flow seeds a CatalogProductSynced event before placing the order.
@@reventless.gwt

// Compose the automation onto a flat slice — the production split keeps
// collect/resolve inside the per-source mapping; the GWT needs them together.
let contextFor = (sliceName): Reventless.AutomationSlice.context => {
  environment: "test",
  platformName: "test",
  pluginName: "ordering",
  sliceName,
}

module AutoShipOrderSlice = {
  include AutoShipOrder
  type consumedEvent = AutoShipOrder_Automation.FromOrderingDcb.sourceEvent
  let consumedEventSchema = AutoShipOrder_Automation.FromOrderingDcb.sourceEventSchema
  let collect = e => AutoShipOrder_Automation.FromOrderingDcb.collect(e, ~sourceId="", contextFor("AutoShipOrder"))
  let resolve = AutoShipOrder_Automation.FromOrderingDcb.resolve
  let process = AutoShipOrder_Automation.process
}

// The DCB half of the intake relay. Its Customer-aggregate half announces
// contacts and has nothing to do with an order, so this flow does not thread it.
module NotificationIntakeSlice = {
  include NotificationIntake
  type consumedEvent = NotificationIntake_Automation.FromOrderingDcb.sourceEvent
  let consumedEventSchema = NotificationIntake_Automation.FromOrderingDcb.sourceEventSchema
  let collect = e =>
    NotificationIntake_Automation.FromOrderingDcb.collect(e, ~sourceId="", contextFor("NotificationIntake"))
  let resolve = NotificationIntake_Automation.FromOrderingDcb.resolve
  let process = NotificationIntake_Automation.process
}

module Sync = CommandStep(SyncCatalogProduct, SyncCatalogProduct_Behavior)
module Place = CommandStep(PlaceOrder, PlaceOrder_Behavior)
module Auto = AutomationStep(AutoShipOrderSlice)
module Ship = CommandStep(ShipOrder, ShipOrder_Behavior)
module OrdersView = ViewStep(Orders, Orders_Projection)
module Notify = AutomationStep(NotificationIntakeSlice)

// Prices are money, so a test writes the amount a person would say and converts
// it once. `ofMajor` scales by the currency's own exponent, which is what keeps
// the literal honest: 9.99 EUR is 999 cents, and the same call on a JPY price
// would scale by 1.
let eur = amount => Reventless.Money.ofMajor(~amount, ~currency=EUR)

describe("Ordering flow — place → auto-ship → confirm", () => {
  test("an order is placed, auto-shipped, projected as Shipped, and confirmed", () => {
    // The requested delivery slot travels command → event → view row unchanged,
    // one `DateRange` end to end.
    let window = Reventless.DateRange.make(
      ~start="2026-03-02T09:00:00Z",
      ~end_="2026-03-02T11:00:00Z",
    )->Result.getOrThrow
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
        deliveryWindow: window,
      }),
    )
    ->Place.thenEvent(
      PlaceOrder.OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Express,
        deliveryWindow: window,
      }),
    )
    ->Auto.whenReacts
    ->Auto.thenIssuesCommand(AutoShipOrder.ShipOrder({orderId: "o1"}))
    ->Ship.whenCommand(ShipOrder.ShipOrder({orderId: "o1"}))
    ->Ship.thenEvent(ShipOrder.OrderShipped({orderId: "o1", customerId: "c1"}))
    ->OrdersView.thenViewState(
      "o1",
      {
        Orders.orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lifecycle: Shipped,
        shippingMethod: Express,
        placedAt: "time",
        shippedAt: "time",
        deliveryWindow: Some(window),
      },
    )
    // The relay asks for the notifications and says nothing about how they go
    // out. `reference` is the relay's own key for each occurrence, echoed back on
    // the outcome so the row it opened can be closed — one key per occurrence, so
    // the confirmation's outcome cannot close the shipping update's row.
    //
    // Two commands from one sweep is the point: the order lane produced two
    // notifiable facts, and the relay carries both across without either one
    // knowing what the other's category is.
    ->Notify.whenReacts
    ->Notify.thenIssuesCommands([
      NotificationIntake.RequestNotification({
        recipientId: "c1",
        category: OrderConfirmation,
        reference: "confirm:o1",
        subject: "Your order o1 is confirmed",
        body: "Thanks — we have your order o1 and will let you know when it ships.",
      }),
      NotificationIntake.RequestNotification({
        recipientId: "c1",
        category: ShippingUpdate,
        reference: "ship:o1",
        subject: "Your order o1 is on its way",
        body: "Good news — order o1 has shipped.",
      }),
    ])
  })

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
