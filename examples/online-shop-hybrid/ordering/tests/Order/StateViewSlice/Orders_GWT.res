@@reventless.gwt

describe("Orders StateViewSlice", () => {
  test("OrderPlaced creates a row with status Placed", () =>
    givenEvents([])
    ->whenEvent(
      OrderPlaced({orderId: "o1", customerId: "c1", productId: ["p1", "p2"]}),
    )
    ->thenStateWithId(
      "o1",
      {orderId: "o1", customerId: "c1", productId: ["p1", "p2"], status: Placed},
    )
  )

  test("OrderShipped updates status to Shipped", () =>
    givenEvents([
      OrderPlaced({orderId: "o1", customerId: "c1", productId: ["p1"]}),
    ])
    ->whenEvent(OrderShipped({orderId: "o1"}))
    ->thenStateWithId(
      "o1",
      {orderId: "o1", customerId: "c1", productId: ["p1"], status: Shipped},
    )
  )

  test("OrderCancelled updates status to Cancelled", () =>
    givenEvents([
      OrderPlaced({orderId: "o1", customerId: "c1", productId: ["p1"]}),
    ])
    ->whenEvent(OrderCancelled({orderId: "o1"}))
    ->thenStateWithId(
      "o1",
      {orderId: "o1", customerId: "c1", productId: ["p1"], status: Cancelled},
    )
  )
})
