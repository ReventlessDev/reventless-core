@@reventless.gwt

describe("ShipOrder StateChangeSlice", () => {
  test("non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(ShipOrder({orderId: "o1"}))
    ->thenError(OrderNotFound)
  )

  test("placed order produces OrderShipped", () =>
    givenEvents([OrderPlaced({productIds: ["p1"]})])
    ->whenCmd(ShipOrder({orderId: "o1"}))
    ->thenEvent(OrderShipped({orderId: "o1"}))
  )

  test("already shipped order produces no events (idempotent)", () =>
    givenEvents([OrderPlaced({productIds: ["p1"]}), OrderShipped])
    ->whenCmd(ShipOrder({orderId: "o1"}))
    ->thenNoEvent
  )

  test("cancelled order returns OrderAlreadyCancelled", () =>
    givenEvents([OrderPlaced({productIds: ["p1"]}), OrderCancelled])
    ->whenCmd(ShipOrder({orderId: "o1"}))
    ->thenError(OrderAlreadyCancelled)
  )

  // The case the slice used to get wrong. It folded `OrderCancelled` without
  // ever hearing `OrderReopened`, so a reopened order stayed cancelled here for
  // good and could never ship again — while `CancelOrder`, which does consume
  // the reopen, happily kept issuing it. Nothing in the declaration was wrong;
  // the two folds simply disagreed, and only running them says so.
  test("reopened order can ship again", () =>
    givenEvents([OrderPlaced({productIds: ["p1"]}), OrderCancelled, OrderReopened])
    ->whenCmd(ShipOrder({orderId: "o1"}))
    ->thenEvent(OrderShipped({orderId: "o1"}))
  )
})
