@@reventless.gwt(Orders_Projections.OrderMapping)

// Ids are typed; the literals are made once, here.
let cust1 = CustomerId.make("cust-1")
let prod1 = CatalogSpec.ProductId.make("prod-1")
let prod2 = CatalogSpec.ProductId.make("prod-2")

describe("Orders ReadModel ← Order", () => {
  // scenario-id: 94f5938c-adf9-42c2-8986-1204e0aa0710
  test("Placed sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(Order.Placed({customerId: cust1, productIds: [prod1, prod2]}))
    ->thenState({
      Orders.customerId: cust1,
      productIds: [prod1, prod2],
      lifecycle: Placed,
    })
  )

  // scenario-id: 4b7e916e-e7db-4c00-9337-9e2fe4104c93
  test("Shipped updates status", () =>
    givenEvents([Order.Placed({customerId: cust1, productIds: [prod1]})])
    ->whenEvent(Order.Shipped)
    ->thenState({
      Orders.customerId: cust1,
      productIds: [prod1],
      lifecycle: Shipped,
    })
  )

  // scenario-id: a56314fa-907f-425a-80e6-a7ea1a27d6c9
  test("Cancelled updates status", () =>
    givenEvents([Order.Placed({customerId: cust1, productIds: [prod1]})])
    ->whenEvent(Order.Cancelled({productIds: [prod1]}))
    ->thenState({
      Orders.customerId: cust1,
      productIds: [prod1],
      lifecycle: Cancelled,
    })
  )

  // scenario-id: 96902cd1-2eae-4a35-b5c6-6d28dc9acda7
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
