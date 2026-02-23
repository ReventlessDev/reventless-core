// Unit tests for Order projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

include Reventless.ProjectionTest.Make(OrdersProjections.OrderMapping)

describe("OrderProjection:", () => {
  test("OrderPlaced sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(
      Order.OrderPlaced({
        orderId: "ord-1",
        customerId: "cust-1",
        productIds: ["prod-1", "prod-2"],
      }),
    )
    ->thenState({
      OrdersReadModel.orderId: "ord-1",
      customerId: "cust-1",
      productIds: ["prod-1", "prod-2"],
      status: "placed",
    })
  )

  test("OrderShipped after placing updates status to shipped", () =>
    givenEvents([
      Order.OrderPlaced({orderId: "ord-1", customerId: "cust-1", productIds: ["prod-1"]}),
    ])
    ->whenEvent(Order.OrderShipped({orderId: "ord-1"}))
    ->thenState({
      OrdersReadModel.orderId: "ord-1",
      customerId: "cust-1",
      productIds: ["prod-1"],
      status: "shipped",
    })
  )

  test("OrderCancelled after placing updates status to cancelled", () =>
    givenEvents([
      Order.OrderPlaced({orderId: "ord-1", customerId: "cust-1", productIds: ["prod-1"]}),
    ])
    ->whenEvent(Order.OrderCancelled({orderId: "ord-1"}))
    ->thenState({
      OrdersReadModel.orderId: "ord-1",
      customerId: "cust-1",
      productIds: ["prod-1"],
      status: "cancelled",
    })
  )
})
