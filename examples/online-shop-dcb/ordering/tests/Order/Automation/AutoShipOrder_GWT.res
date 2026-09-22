// `Automation_GWT.Make` expects a single SliceSpec with `collect`, `resolve`
// and `process` as top-level bindings. The split-form production layout puts
// `collect`/`resolve` inside the per-source `FromOrderingDcb` mapping, so we
// compose the pieces locally before handing the result to the DSL.

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

  let collect = e => AutoShipOrder_Automation.FromOrderingDcb.collect(e, ~sourceId="", testContext)
  let resolve = AutoShipOrder_Automation.FromOrderingDcb.resolve
  let process = AutoShipOrder_Automation.process
}

@@reventless.gwt

open OrderingExamples

let oid = OrderId.make

describe("AutoShipOrder AutomationSlice", () => {
  // scenario-id: 02131883-ffbd-430f-a186-86d79daf5fb4
  test("collect: OrderPlaced creates a pending TODO", () =>
    givenEvent(OrderPlaced({orderId: o1}))
    ->whenCollect
    ->thenTodos([("o1", {orderId: oid("o1")})])
  )

  // scenario-id: 9f6c8137-a3ee-4bcd-8f22-59c028d3859e
  test("collect: OrderShipped is ignored (no TODO)", () =>
    givenEvent(OrderShipped({orderId: o1}))
    ->whenCollect
    ->thenTodos([])
  )

  // scenario-id: 0d773a65-4422-45d1-a861-a3b61d144bc5
  test("resolve: OrderShipped marks the TODO done", () =>
    givenEvent(OrderShipped({orderId: o1}))
    ->whenResolve
    ->thenResolved(Some("o1"))
  )

  // scenario-id: def98dd4-ed82-4d4b-9d93-7fd6f77278a4
  test("resolve: OrderPlaced does not mark anything done", () =>
    givenEvent(OrderPlaced({orderId: o1}))
    ->whenResolve
    ->thenResolved(None)
  )

  // scenario-id: c33672f2-3c0a-489f-baed-79eb15963354
  test("process: pending TODO emits ShipOrder for the same id", () =>
    givenTodo("o1", {orderId: o1})
    ->whenProcess
    ->thenCommand("o1", ShipOrder({orderId: o1}))
  )
})
