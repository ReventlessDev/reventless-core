// `Automation_GWT.Make` expects a single SliceSpec with `collect`, `resolve`
// and `process` as top-level bindings. Compose them onto the spec module
// locally — the production split form keeps `collect`/`resolve` inside the
// per-source mapping.

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

@@reventless.gwt

describe("AutoShipOrder AutomationSlice", () => {
  test("collect: OrderPlaced creates a pending TODO", () =>
    givenEvent(OrderPlaced({orderId: "o1"}))
    ->whenCollect
    ->thenTodos([("o1", {orderId: "o1"})])
  )

  test("collect: OrderShipped is ignored (no TODO)", () =>
    givenEvent(OrderShipped({orderId: "o1"}))
    ->whenCollect
    ->thenTodos([])
  )

  test("resolve: OrderShipped marks the TODO done", () =>
    givenEvent(OrderShipped({orderId: "o1"}))
    ->whenResolve
    ->thenResolved(Some("o1"))
  )

  test("resolve: OrderPlaced does not mark anything done", () =>
    givenEvent(OrderPlaced({orderId: "o1"}))
    ->whenResolve
    ->thenResolved(None)
  )

  test("process: pending TODO emits ShipOrder for the same id", () =>
    givenTodo("o1", {orderId: "o1"})
    ->whenProcess
    ->thenCommand("o1", ShipOrder({orderId: "o1"}))
  )
})
