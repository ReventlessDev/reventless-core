@@reventless.gwt

open Ordering_Examples

describe("ShipOrder StateChangeSlice", () => {
  // scenario-id: 12e1d195-e91c-40c9-bc0f-6b28bf7d7b60
  test("non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(ShipOrder({orderId: o1}))
    ->thenError(OrderNotFound)
  )

  // scenario-id: 2bb4cd67-da26-4d53-adc4-6a01115727f3
  test("placed order produces OrderShipped", () =>
    givenEvents([OrderPlaced({productIds: [p1], customerId: c1})])
    ->whenCmd(ShipOrder({orderId: o1}))
    ->thenEvent(OrderShipped({orderId: o1, customerId: c1}))
  )

  // scenario-id: 6258f27d-3e1f-4fd2-9a8e-59005214959b
  test("already shipped order produces no events (idempotent)", () =>
    givenEvents([OrderPlaced({productIds: [p1], customerId: c1}), OrderShipped])
    ->whenCmd(ShipOrder({orderId: o1}))
    ->thenNoEvent
  )

  // scenario-id: f538073e-ac2f-4fb1-ae3c-695ab09e8657
  test("cancelled order returns OrderAlreadyCancelled", () =>
    givenEvents([OrderPlaced({productIds: [p1], customerId: c1}), OrderCancelled])
    ->whenCmd(ShipOrder({orderId: o1}))
    ->thenError(OrderAlreadyCancelled)
  )

  // The case the slice used to get wrong. It folded `OrderCancelled` without
  // ever hearing `OrderReopened`, so a reopened order stayed cancelled here for
  // good and could never ship again — while `CancelOrder`, which does consume
  // the reopen, happily kept issuing it. Nothing in the declaration was wrong;
  // the two folds simply disagreed, and only running them says so.
  // scenario-id: 1ab94741-88da-4951-9279-09cc7af9618a
  test("reopened order can ship again", () =>
    givenEvents([OrderPlaced({productIds: [p1], customerId: c1}), OrderCancelled, OrderReopened])
    ->whenCmd(ShipOrder({orderId: o1}))
    ->thenEvent(OrderShipped({orderId: o1, customerId: c1}))
  )
})
