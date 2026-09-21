@@reventless.gwt

let oid = OrderId.make

describe("ShipOrder StateChangeSlice", () => {
  test("non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(ShipOrder({orderId: oid("o1")}))
    ->thenError(OrderNotFound)
  )

  test("placed order produces OrderShipped", () =>
    givenEvents([OrderPlaced])
    ->whenCmd(ShipOrder({orderId: oid("o1")}))
    ->thenEvent(OrderShipped({orderId: oid("o1")}))
  )

  test("already shipped order produces no events (idempotent)", () =>
    givenEvents([OrderPlaced, OrderShipped])
    ->whenCmd(ShipOrder({orderId: oid("o1")}))
    ->thenNoEvent
  )

  test("cancelled order returns OrderAlreadyCancelled", () =>
    givenEvents([OrderPlaced, OrderCancelled])
    ->whenCmd(ShipOrder({orderId: oid("o1")}))
    ->thenError(OrderAlreadyCancelled)
  )
})
