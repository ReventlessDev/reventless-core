@@reventless.gwt(Orders_Projections.OrderMapping)

describe("Orders ReadModel ← Order", () => {
  test("Placed sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(Order.Placed({customerId: "cust-1", productIds: ["prod-1", "prod-2"]}))
    ->thenState({
      Orders.customerId: "cust-1",
      productIds: ["prod-1", "prod-2"],
      status: Placed,
    })
  )

  test("Shipped updates status", () =>
    givenEvents([Order.Placed({customerId: "cust-1", productIds: ["prod-1"]})])
    ->whenEvent(Order.Shipped)
    ->thenState({
      Orders.customerId: "cust-1",
      productIds: ["prod-1"],
      status: Shipped,
    })
  )

  test("Cancelled updates status", () =>
    givenEvents([Order.Placed({customerId: "cust-1", productIds: ["prod-1"]})])
    ->whenEvent(Order.Cancelled({productIds: ["prod-1"]}))
    ->thenState({
      Orders.customerId: "cust-1",
      productIds: ["prod-1"],
      status: Cancelled,
    })
  )
})
