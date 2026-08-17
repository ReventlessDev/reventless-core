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
        deliveryWindow: None,
      }),
    )
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1", "p2"],
        lifecycle: Placed,
        shippingMethod: Standard,
        placedAt: "time",
        shippedAt: "",
        deliveryWindow: None,
      },
    )
  )

  // The declared span is carried straight from the event onto the row, with
  // `customerId` beside it as the resource ref — which is what lets a scheduler
  // mode lay a bar out from the row without guessing the pair from field names.
  test("a requested delivery window lands on the row", () => {
    let window = Reventless.DateRange.make(
      ~start="2026-03-02T09:00:00Z",
      ~end_="2026-03-02T11:00:00Z",
    )->Result.getOrThrow
    givenEvents([])
    ->whenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        deliveryWindow: Some(window),
      }),
    )
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lifecycle: Placed,
        shippingMethod: Standard,
        placedAt: "time",
        shippedAt: "",
        deliveryWindow: Some(window),
      },
    )
  })

  test("the shipping method chosen at placement is projected onto the row", () =>
    givenEvents([])
    ->whenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Pickup,
        deliveryWindow: None,
      }),
    )
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lifecycle: Placed,
        shippingMethod: Pickup,
        placedAt: "time",
        shippedAt: "",
        deliveryWindow: None,
      },
    )
  )

  test("OrderShipped updates status to Shipped", () =>
    givenEvents([
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Express,
        deliveryWindow: None,
      }),
    ])
    ->whenEvent(OrderShipped({orderId: "o1"}))
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lifecycle: Shipped,
        shippingMethod: Express,
        placedAt: "time",
        shippedAt: "time",
        deliveryWindow: None,
      },
    )
  )

  test("OrderCancelled updates status to Cancelled", () =>
    givenEvents([
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        deliveryWindow: None,
      }),
    ])
    ->whenEvent(OrderCancelled({orderId: "o1"}))
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lifecycle: Cancelled,
        shippingMethod: Standard,
        placedAt: "time",
        shippedAt: "",
        deliveryWindow: None,
      },
    )
  )

  // The way back. A cancelled order that is reopened is `Placed` again, and
  // `ShipOrder` says so on its own side — so a view that did not fold this event
  // would leave a reopened order rendering `Cancelled` for the rest of its life
  // while shipping perfectly well. The two halves have to agree, and only a
  // scenario on each says whether they do.
  test("OrderReopened puts a cancelled order back to Placed", () =>
    givenEvents([
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        deliveryWindow: None,
      }),
      OrderCancelled({orderId: "o1"}),
    ])
    ->whenEvent(OrderReopened({orderId: "o1"}))
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lifecycle: Placed,
        shippingMethod: Standard,
        placedAt: "time",
        shippedAt: "",
        deliveryWindow: None,
      },
    )
  )
})
