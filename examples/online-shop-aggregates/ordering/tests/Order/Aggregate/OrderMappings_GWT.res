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

let placedEvent = Order.Placed({customerId: "cust-1", productIds: ["prod-1"]})

describe("Order auto-ship mapping (Placed → Ship)", () => {
  test("Place → AutoShipMapping issues Ship → target emits Shipped", () =>
    givenSourceEvents([])
    ->andTargetEvents([("order-1", [placedEvent])])
    ->whenSourceCmd("order-1", Place({customerId: "cust-1", productIds: ["prod-1"]}))
    ->thenTargetEvent("order-1", Order.Shipped)
  )

  test("Ship command does not fire the mapping (only Placed events do)", () =>
    givenSourceEvents([placedEvent])
    ->andTargetEvents([("order-1", [placedEvent])])
    ->whenSourceCmd("order-1", Ship)
    ->thenNoTargetEvent
  )

  test("Cancel command does not fire the mapping", () =>
    givenSourceEvents([placedEvent])
    ->andTargetEvents([("order-1", [placedEvent])])
    ->whenSourceCmd("order-1", Cancel)
    ->thenNoTargetEvent
  )
})
