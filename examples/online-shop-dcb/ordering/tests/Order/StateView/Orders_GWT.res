@@reventless.gwt

open Ordering_Examples

describe("Orders StateViewSlice", () => {
  // scenario-id: 7967e51a-49fb-4f1e-81f8-a4feabeccf8a
  test("OrderPlaced creates a row with status Placed", () =>
    givenEvents([])
    ->whenEvent(OrderPlaced({orderId: o1, customerId: c1, productIds: [p1, p2]}))
    ->thenStateWithId(
      "o1",
      {
        orderId: o1,
        customerId: c1,
        productIds: [p1, p2],
        lifecycle: Placed,
      },
    )
  )

  // scenario-id: e97d9c01-c2e6-48c1-82d2-3cc2e7c8e401
  test("OrderShipped updates status to Shipped", () =>
    givenEvents([OrderPlaced({orderId: o1, customerId: c1, productIds: [p1]})])
    ->whenEvent(OrderShipped({orderId: o1}))
    ->thenStateWithId("o1", {orderId: o1, customerId: c1, productIds: [p1], lifecycle: Shipped})
  )

  // scenario-id: 94ff556f-1d4d-444d-8eda-0a9192715489
  test("OrderCancelled updates status to Cancelled", () =>
    givenEvents([OrderPlaced({orderId: o1, customerId: c1, productIds: [p1]})])
    ->whenEvent(OrderCancelled({orderId: o1}))
    ->thenStateWithId("o1", {orderId: o1, customerId: c1, productIds: [p1], lifecycle: Cancelled})
  )
})
