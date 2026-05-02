@@reventless.gwt

describe("PlaceOrder StateChangeSlice", () => {
  test("empty event log produces OrderPlaced", () =>
    givenEvents([])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1", "p2"]}),
    )
    ->thenEvent(
      OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1", "p2"]}),
    )
  )

  test("existing order returns OrderAlreadyPlaced", () =>
    givenEvents([OrderPlaced])
    ->whenCmd(PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"]}))
    ->thenError(OrderAlreadyPlaced)
  )
})
