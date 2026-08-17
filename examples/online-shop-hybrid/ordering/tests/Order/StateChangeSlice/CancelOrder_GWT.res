@@reventless.gwt

describe("CancelOrder StateChangeSlice", () => {
  test("non-existent order returns OrderNotFound for CancelOrder", () =>
    givenEvents([])
    ->whenCmd(CancelOrder({orderId: "o1"}))
    ->thenError(OrderNotFound)
  )

  test("placed order produces OrderCancelled with productIds carried over", () =>
    givenEvents([OrderPlaced({productIds: ["p1", "p2"]})])
    ->whenCmd(CancelOrder({orderId: "o1"}))
    ->thenEvent(OrderCancelled({orderId: "o1", productIds: ["p1", "p2"]}))
  )

  test("already cancelled order produces no events for CancelOrder (idempotent)", () =>
    givenEvents([OrderPlaced({productIds: ["p1"]}), OrderCancelled])
    ->whenCmd(CancelOrder({orderId: "o1"}))
    ->thenNoEvent
  )

  test("shipped order returns OrderAlreadyShipped for CancelOrder", () =>
    givenEvents([OrderPlaced({productIds: ["p1"]}), OrderShipped])
    ->whenCmd(CancelOrder({orderId: "o1"}))
    ->thenError(OrderAlreadyShipped)
  )

  test("ReopenOrder on cancelled order produces OrderReopened", () =>
    givenEvents([OrderPlaced({productIds: ["p1"]}), OrderCancelled])
    ->whenCmd(ReopenOrder({orderId: "o1"}))
    ->thenEvent(OrderReopened({orderId: "o1"}))
  )

  test("ReopenOrder on a placed order produces no events (idempotent)", () =>
    givenEvents([OrderPlaced({productIds: ["p1"]})])
    ->whenCmd(ReopenOrder({orderId: "o1"}))
    ->thenNoEvent
  )

  // A shipped order is not a cancelled one, so reopening it is not a repeat of
  // anything. Accepting it silently reported success while the order stayed
  // shipped — the case no test covered, which is how it survived.
  test("ReopenOrder on a shipped order returns OrderAlreadyShipped", () =>
    givenEvents([OrderPlaced({productIds: ["p1"]}), OrderShipped])
    ->whenCmd(ReopenOrder({orderId: "o1"}))
    ->thenError(OrderAlreadyShipped)
  )

  test("ReopenOrder on non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(ReopenOrder({orderId: "o1"}))
    ->thenError(OrderNotFound)
  )
})
