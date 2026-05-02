// Unit tests for Order projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

include ReventlessGwt.MultiSourceProjection_GWT.Make(Orders_Projections.OrderMapping)

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
      Orders.customerId: "cust-1",
      productIds: ["prod-1", "prod-2"],
      status: Placed,
    })
  )

  test("Shipped after placing updates status to shipped", () =>
    givenEvents([Order.Placed({customerId: "cust-1", productIds: ["prod-1"]})])
    ->whenEvent(Order.Shipped)
    ->thenState({
      Orders.customerId: "cust-1",
      productIds: ["prod-1"],
      status: Shipped,
    })
  )

  test("Cancelled after placing updates status to cancelled", () =>
    givenEvents([Order.Placed({customerId: "cust-1", productIds: ["prod-1"]})])
    ->whenEvent(Order.Cancelled({productIds: ["prod-1"]}))
    ->thenState({
      Orders.customerId: "cust-1",
      productIds: ["prod-1"],
      status: Cancelled,
    })
  )
})
