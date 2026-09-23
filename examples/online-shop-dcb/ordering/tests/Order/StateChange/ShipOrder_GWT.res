@@reventless.gwt

open Ordering_Examples

describe("ShipOrder StateChangeSlice", () => {
  // scenario-id: 2146c7ce-d052-4b18-8d15-373916445f80
  test("non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(ShipOrder({orderId: o1}))
    ->thenError(OrderNotFound)
  )

  // scenario-id: 76062151-57bb-468b-9fee-915e35e8d67e
  test("placed order produces OrderShipped", () =>
    givenEvents([OrderPlaced])
    ->whenCmd(ShipOrder({orderId: o1}))
    ->thenEvent(OrderShipped({orderId: o1}))
  )

  // scenario-id: 3ffc1f1f-8611-4c99-90b3-435b441140d3
  test("already shipped order produces no events (idempotent)", () =>
    givenEvents([OrderPlaced, OrderShipped])
    ->whenCmd(ShipOrder({orderId: o1}))
    ->thenNoEvent
  )

  // scenario-id: 23a22483-510c-458d-aa40-17c442470b22
  test("cancelled order returns OrderAlreadyCancelled", () =>
    givenEvents([OrderPlaced, OrderCancelled])
    ->whenCmd(ShipOrder({orderId: o1}))
    ->thenError(OrderAlreadyCancelled)
  )
})
