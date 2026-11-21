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

open Ordering_Examples

describe("Ordering flow — place → auto-ship → confirm", () => {
  // scenario-id: 0c04bbd0-be72-479b-9731-73c122f66b20
  test("an order is placed, auto-shipped, projected as Shipped, and confirmed", () => {
    // The requested delivery slot travels command → event → view row unchanged,
    // one `DateRange` end to end.
    let window =
      Reventless.DateRange.make(
        ~start="2026-03-02T09:00:00Z",
        ~end_="2026-03-02T11:00:00Z",
      )->Result.getOrThrow
    start
    ->Flow.SyncCatalogProduct.givenEvents([
      SyncCatalogProduct.CatalogProductSynced({
        productId: p1,
        name: book,
        price: bookPrice,
      }),
    ])
    // Express, so the automation picks it up — a Standard or Pickup order would
    // stop at Placed and wait for an explicit ShipOrder.
    ->Flow.PlaceOrder.whenCommand(
      ~at=placedTime,
      PlaceOrder.PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 2}],
        shippingMethod: Express,
        deliveryWindow: window,
      }),
    )
    ->Flow.PlaceOrder.thenEvent(
      PlaceOrder.OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        // The line is priced from the shelf the placement read, and the total is
        // the sum of the lines — two of a €9.99 book is €19.98, computed by
        // `Money` rather than by the decision.
        lines: [
          {
            productId: p1,
            name: book,
            quantity: 2,
            unitPrice: bookPrice,
            lineTotal: twoBooksPrice,
          },
        ],
        total: twoBooksPrice,
        shippingMethod: Express,
        deliveryWindow: window,
        // Captured off the shelf at placement — the same name the catalog
        // synced above, now part of the order's own record.
        firstProductName: book,
      }),
    )
    ->Flow.AutoShipOrder.whenReacts
    ->Flow.AutoShipOrder.thenIssuesCommand(AutoShipOrder.ShipOrder({orderId: o1}))
    ->Flow.ShipOrder.whenIssued(~at=shippedTime)
    ->Flow.ShipOrder.thenEvent(ShipOrder.OrderShipped({orderId: o1, customerId: c1}))
    ->Flow.Orders.thenRow(
      "o1",
      {
        Orders.orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [
          {
            productId: p1,
            name: book,
            quantity: 2,
            unitPrice: bookPrice,
            lineTotal: twoBooksPrice,
          },
        ],
        total: twoBooksPrice,
        itemCount: 2,
        lifecycle: Shipped,
        shippingMethod: Express,
        placedAt: placedTime,
        // Each entry at the time its step happened: the machinery stamps each
        // envelope's own `meta.time`, which is the flow's time at that step.
        trail: [{state: Placed, at: placedTime}, {state: Shipped, at: shippedTime}],
        deliveryWindow: window,
        firstProductName: book,
        firstProductImage: None,
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
    ->Flow.NotificationIntake.whenReacts
    ->Flow.NotificationIntake.thenIssuesCommands([
      NotificationIntake.RequestNotification({
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
      NotificationIntake.RequestNotification({
        recipientId: customerRef,
        category: ShippingUpdate,
        reference: "ship:o1",
        subjectType: orderSubject,
        subjectRef: orderRef,
        subject: "Your order o1 is on its way",
        body: "Good news — order o1 has shipped.",
        sourceId: "OrderingDcbEventLog:OrderShipped",
        origin: Default,
      }),
    ])
  })

  // scenario-id: c8689953-3429-4fe0-a146-cc9fcfc4a6c6
  test("placing an order for an unsynced product is rejected", () =>
    start
    ->Flow.PlaceOrder.whenCommand(
      PlaceOrder.PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->Flow.PlaceOrder.thenError(ProductsNotAvailable({missing: [p1]}))
  )
})
