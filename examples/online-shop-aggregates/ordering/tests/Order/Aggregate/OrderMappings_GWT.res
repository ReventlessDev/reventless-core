// `Mapping_GWT` exercises Order's self-mapping (auto-ship on placement).
// Bare `@@reventless.gwt` would derive the Behavior DSL from the Aggregate
// folder; the cross-pattern Mapping DSL is wired explicitly instead.
//
// Self-mappings need the target's per-id history pre-seeded with the
// source-emitted event, since Mapping_GWT models source and target as
// independent aggregates even when they're the same one in production.

module OrderSource = ReventlessGwt.Mapping_GWT.FromBehavior(Order, Order_Behavior)
module OrderTarget = ReventlessGwt.Mapping_GWT.FromBehavior(Order, Order_Behavior)

module AutoShipGwtMapping = {
  module Source = OrderSource
  module Target = OrderTarget
  let map = Order_Mappings.AutoShipMapping.map
}

include ReventlessGwt.Mapping_GWT.Make(AutoShipGwtMapping)

let cust1 = CustomerId.make("cust-1")
let prod1 = CatalogSpec.ProductId.make("prod-1")
let placedEvent = Order.Placed({customerId: cust1, productIds: [prod1]})

describe("Order auto-ship mapping (Placed → Ship)", () => {
  // scenario-id: 2fd227c7-248e-47be-939a-467bceeb8796
  test("Place → AutoShipMapping issues Ship → target emits Shipped", () =>
    givenSourceEvents([])
    ->andTargetEvents([("order-1", [placedEvent])])
    ->whenSourceCmd("order-1", Place({customerId: cust1, productIds: [prod1]}))
    ->thenTargetEvent("order-1", Order.Shipped)
  )

  // scenario-id: 366966a9-f65a-44cf-9bd2-4df7ef7bced4
  test("Ship command does not fire the mapping (only Placed events do)", () =>
    givenSourceEvents([placedEvent])
    ->andTargetEvents([("order-1", [placedEvent])])
    ->whenSourceCmd("order-1", Ship)
    ->thenNoTargetEvent
  )

  // scenario-id: c6203367-d2ff-4903-b1a2-8cc259ec62ee
  test("Cancel command does not fire the mapping", () =>
    givenSourceEvents([placedEvent])
    ->andTargetEvents([("order-1", [placedEvent])])
    ->whenSourceCmd("order-1", Cancel)
    ->thenNoTargetEvent
  )

  // scenario-id: d20d610d-7ec8-4767-8d88-4556c1bf7059
  test("Refund command does not fire the mapping (only Placed events do)", () =>
    givenSourceEvents([placedEvent, Order.Cancelled({productIds: [prod1]})])
    ->andTargetEvents([("order-1", [placedEvent, Order.Cancelled({productIds: [prod1]})])])
    ->whenSourceCmd("order-1", Refund({reason: "customer-changed-mind"}))
    ->thenNoTargetEvent
  )
})
