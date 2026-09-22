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

  let collect = e => AutoShipOrder_Automation.FromOrderingDcb.collect(e, ~sourceId="", testContext)
  let resolve = AutoShipOrder_Automation.FromOrderingDcb.resolve
  let process = AutoShipOrder_Automation.process
}

@@reventless.gwt

open OrderingExamples

let oid = OrderId.make

describe("AutoShipOrder AutomationSlice", () => {
  // scenario-id: 1ba638a2-88ea-4f2c-9a4e-1520276a0b37
  test("collect: an Express OrderPlaced creates a pending TODO", () =>
    givenEvent(OrderPlaced({orderId: o1, shippingMethod: Express}))
    ->whenCollect
    ->thenTodos([("o1", {orderId: oid("o1")})])
  )

  // scenario-id: 024094c8-3c62-4061-940f-29a79cfc9c63
  test("collect: a Standard OrderPlaced is left to the batch run (no TODO)", () =>
    givenEvent(OrderPlaced({orderId: o1, shippingMethod: Standard}))
    ->whenCollect
    ->thenTodos([])
  )

  // scenario-id: 9c73692d-e995-4cb3-9b30-cb36d803d91b
  test("collect: a Pickup OrderPlaced is never shipped (no TODO)", () =>
    givenEvent(OrderPlaced({orderId: o1, shippingMethod: Pickup}))
    ->whenCollect
    ->thenTodos([])
  )

  // scenario-id: ed558c2b-1c35-4a59-8a86-e6c623c68fd5
  test("collect: OrderShipped is ignored (no TODO)", () =>
    givenEvent(OrderShipped({orderId: o1}))
    ->whenCollect
    ->thenTodos([])
  )

  // scenario-id: 2342e587-2f28-485d-a328-092859231820
  test("resolve: OrderShipped marks the TODO done", () =>
    givenEvent(OrderShipped({orderId: o1}))
    ->whenResolve
    ->thenResolved(Some("o1"))
  )

  // scenario-id: 219b370b-550c-4bf8-a120-0014fac4adc4
  test("resolve: OrderPlaced does not mark anything done", () =>
    givenEvent(OrderPlaced({orderId: o1, shippingMethod: Express}))
    ->whenResolve
    ->thenResolved(None)
  )

  // scenario-id: 8331145e-fad0-4adb-a879-cbc0922d9cd1
  test("process: pending TODO emits ShipOrder for the same id", () =>
    givenTodo("o1", {orderId: o1})
    ->whenProcess
    ->thenCommand("o1", ShipOrder({orderId: o1}))
  )
})
