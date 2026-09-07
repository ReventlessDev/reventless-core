@@reventless.gwt

describe("CancelOrder StateChangeSlice", () => {
  test("non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(CancelOrder({orderId: "o1"}))
    ->thenError(OrderNotFound)
  )

  test("placed order produces OrderCancelled with productIds carried over", () =>
    givenEvents([OrderPlaced({productIds: ["p1", "p2"]})])
    ->whenCmd(CancelOrder({orderId: "o1"}))
    ->thenEvent(OrderCancelled({orderId: "o1", productIds: ["p1", "p2"]}))
  )

  test("already cancelled order produces no events (idempotent)", () =>
    givenEvents([OrderPlaced({productIds: ["p1"]}), OrderCancelled])
    ->whenCmd(CancelOrder({orderId: "o1"}))
    ->thenNoEvent
  )

  test("shipped order returns OrderAlreadyShipped", () =>
    givenEvents([OrderPlaced({productIds: ["p1"]}), OrderShipped])
    ->whenCmd(CancelOrder({orderId: "o1"}))
    ->thenError(OrderAlreadyShipped)
  )
})
