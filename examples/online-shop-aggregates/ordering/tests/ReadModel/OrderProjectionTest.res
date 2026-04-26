// Unit tests for Order projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

include ReventlessGwt.MultiSourceProjection_GWT.Make(OrdersProjections.OrderMapping)

describe("OrderProjection:", () => {
  test("Placed sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(
      Order.Placed({
        customerId: "cust-1",
        productIds: ["prod-1", "prod-2"],
      }),
    )
    ->thenState({
      OrdersReadModel.customerId: "cust-1",
      productIds: ["prod-1", "prod-2"],
      status: "placed",
    })
  )

  test("Shipped after placing updates status to shipped", () =>
    givenEvents([Order.Placed({customerId: "cust-1", productIds: ["prod-1"]})])
    ->whenEvent(Order.Shipped)
    ->thenState({
      OrdersReadModel.customerId: "cust-1",
      productIds: ["prod-1"],
      status: "shipped",
    })
  )

  test("Cancelled after placing updates status to cancelled", () =>
    givenEvents([Order.Placed({customerId: "cust-1", productIds: ["prod-1"]})])
    ->whenEvent(Order.Cancelled({productIds: ["prod-1"]}))
    ->thenState({
      OrdersReadModel.customerId: "cust-1",
      productIds: ["prod-1"],
      status: "cancelled",
    })
  )
})
