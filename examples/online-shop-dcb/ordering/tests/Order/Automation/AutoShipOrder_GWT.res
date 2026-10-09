@@reventless.gwt

include Mapping(FromOrderingDcb)

open Ordering_Examples

describe("AutoShipOrder AutomationSlice", () => {
  // scenario-id: 02131883-ffbd-430f-a186-86d79daf5fb4
  test("collect: OrderPlaced creates a pending TODO", () =>
    givenEvent(OrderPlaced({orderId: o1}))
    ->whenCollect
    ->thenTodos([("o1", {orderId: o1})])
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
