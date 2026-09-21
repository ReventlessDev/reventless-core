@@reventless.gwt(Orders_Projections.OrderMapping)

// Ids are typed; the literals are made once, here.
let cust1 = CustomerId.make("cust-1")
let prod1 = CatalogSpec.ProductId.make("prod-1")
let prod2 = CatalogSpec.ProductId.make("prod-2")

describe("Orders ReadModel ← Order", () => {
  test("Placed sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(Order.Placed({customerId: cust1, productIds: [prod1, prod2]}))
    ->thenState({
      Orders.customerId: cust1,
      productIds: [prod1, prod2],
      lifecycle: Placed,
    })
  )

  test("Shipped updates status", () =>
    givenEvents([Order.Placed({customerId: cust1, productIds: [prod1]})])
    ->whenEvent(Order.Shipped)
    ->thenState({
      Orders.customerId: cust1,
      productIds: [prod1],
      lifecycle: Shipped,
    })
  )

  test("Cancelled updates status", () =>
    givenEvents([Order.Placed({customerId: cust1, productIds: [prod1]})])
    ->whenEvent(Order.Cancelled({productIds: [prod1]}))
    ->thenState({
      Orders.customerId: cust1,
      productIds: [prod1],
      lifecycle: Cancelled,
    })
  )

  test("Refunded updates status", () =>
    givenEvents([
      Order.Placed({customerId: cust1, productIds: [prod1]}),
      Order.Cancelled({productIds: [prod1]}),
    ])
    ->whenEvent(Order.Refunded({reason: "customer-changed-mind"}))
    ->thenState({
      Orders.customerId: cust1,
      productIds: [prod1],
      lifecycle: Refunded,
    })
  )
})
