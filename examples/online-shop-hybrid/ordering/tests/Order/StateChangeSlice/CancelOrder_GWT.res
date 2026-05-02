@@reventless.gwt

describe("CancelOrder StateChangeSlice", () => {
  test("non-existent order returns OrderNotFound for CancelOrder", () =>
    givenEvents([])
    ->whenCmd(CancelOrder({orderId: "o1"}))
    ->thenError(OrderNotFound)
  )

  test("placed order produces OrderCancelled with productId carried over", () =>
    givenEvents([OrderPlaced({productId: ["p1", "p2"]})])
    ->whenCmd(CancelOrder({orderId: "o1"}))
    ->thenEvent(OrderCancelled({orderId: "o1", productId: ["p1", "p2"]}))
  )

  test("already cancelled order produces no events for CancelOrder (idempotent)", () =>
    givenEvents([OrderPlaced({productId: ["p1"]}), OrderCancelled])
    ->whenCmd(CancelOrder({orderId: "o1"}))
    ->thenNoEvent
  )

  test("shipped order returns OrderAlreadyShipped for CancelOrder", () =>
    givenEvents([OrderPlaced({productId: ["p1"]}), OrderShipped])
    ->whenCmd(CancelOrder({orderId: "o1"}))
    ->thenError(OrderAlreadyShipped)
  )

  test("ReopenOrder on cancelled order produces OrderReopened", () =>
    givenEvents([OrderPlaced({productId: ["p1"]}), OrderCancelled])
    ->whenCmd(ReopenOrder({orderId: "o1"}))
    ->thenEvent(OrderReopened({orderId: "o1"}))
  )

  test("ReopenOrder on non-cancelled order produces no events (idempotent)", () =>
    givenEvents([OrderPlaced({productId: ["p1"]})])
    ->whenCmd(ReopenOrder({orderId: "o1"}))
    ->thenNoEvent
  )

  test("ReopenOrder on non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(ReopenOrder({orderId: "o1"}))
    ->thenError(OrderNotFound)
  )
})
