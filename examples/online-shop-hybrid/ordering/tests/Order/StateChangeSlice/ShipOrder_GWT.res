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
})
