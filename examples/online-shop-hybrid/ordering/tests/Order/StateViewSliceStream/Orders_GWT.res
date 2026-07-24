@@reventless.gwt

describe("Orders StateViewSlice", () => {
  test("OrderPlaced creates a row with status Placed", () =>
    givenEvents([])
    ->whenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1", "p2"],
        shippingMethod: Standard,
      }),
    )
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1", "p2"],
        status: Placed,
        shippingMethod: Standard,
      },
    )
  )

  test("the shipping method chosen at placement is projected onto the row", () =>
    givenEvents([])
    ->whenEvent(
      OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Pickup}),
    )
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        status: Placed,
        shippingMethod: Pickup,
      },
    )
  )

  test("OrderShipped updates status to Shipped", () =>
    givenEvents([
      OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Express}),
    ])
    ->whenEvent(OrderShipped({orderId: "o1"}))
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        status: Shipped,
        shippingMethod: Express,
      },
    )
  )

  test("OrderCancelled updates status to Cancelled", () =>
    givenEvents([
      OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    ])
    ->whenEvent(OrderCancelled({orderId: "o1"}))
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        status: Cancelled,
        shippingMethod: Standard,
      },
    )
  )
})
