@@reventless.gwt

describe("Order Behavior", () => {
  test("Place on new aggregate produces Placed", () =>
    givenEvents([])
    ->whenCmd(Place({customerId: "cust-1", productIds: ["prod-1", "prod-2"]}))
    ->thenEvent(Placed({customerId: "cust-1", productIds: ["prod-1", "prod-2"]}))
  )

  test("Place on existing order returns OrderAlreadyPlaced", () =>
    givenEvents([Placed({customerId: "cust-1", productIds: ["prod-1"]})])
    ->whenCmd(Place({customerId: "cust-1", productIds: ["prod-1"]}))
    ->thenError(OrderAlreadyPlaced)
  )

  test("Place on shipped order returns OrderAlreadyShipped", () =>
    givenEvents([Placed({customerId: "cust-1", productIds: ["prod-1"]}), Shipped])
    ->whenCmd(Place({customerId: "cust-1", productIds: ["prod-1"]}))
    ->thenError(OrderAlreadyShipped)
  )

  test("Place on cancelled order returns OrderAlreadyCancelled", () =>
    givenEvents([
      Placed({customerId: "cust-1", productIds: ["prod-1"]}),
      Cancelled({productIds: ["prod-1"]}),
    ])
    ->whenCmd(Place({customerId: "cust-1", productIds: ["prod-1"]}))
    ->thenError(OrderAlreadyCancelled)
  )

  test("Ship on non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(Ship)
    ->thenError(OrderNotFound)
  )

  test("Ship on placed order produces Shipped", () =>
    givenEvents([Placed({customerId: "cust-1", productIds: ["prod-1"]})])
    ->whenCmd(Ship)
    ->thenEvent(Shipped)
  )

  test("Ship on shipped order produces no events (idempotent)", () =>
    givenEvents([Placed({customerId: "cust-1", productIds: ["prod-1"]}), Shipped])
    ->whenCmd(Ship)
    ->thenNoEvent
  )

  test("Ship on cancelled order returns OrderAlreadyCancelled", () =>
    givenEvents([
      Placed({customerId: "cust-1", productIds: ["prod-1"]}),
      Cancelled({productIds: ["prod-1"]}),
    ])
    ->whenCmd(Ship)
    ->thenError(OrderAlreadyCancelled)
  )

  test("Cancel on non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(Cancel)
    ->thenError(OrderNotFound)
  )

  test("Cancel on placed order produces Cancelled", () =>
    givenEvents([Placed({customerId: "cust-1", productIds: ["prod-1"]})])
    ->whenCmd(Cancel)
    ->thenEvent(Cancelled({productIds: ["prod-1"]}))
  )

  test("Cancel on shipped order returns OrderAlreadyShipped", () =>
    givenEvents([Placed({customerId: "cust-1", productIds: ["prod-1"]}), Shipped])
    ->whenCmd(Cancel)
    ->thenError(OrderAlreadyShipped)
  )

  test("Cancel on cancelled order produces no events (idempotent)", () =>
    givenEvents([
      Placed({customerId: "cust-1", productIds: ["prod-1"]}),
      Cancelled({productIds: ["prod-1"]}),
    ])
    ->whenCmd(Cancel)
    ->thenNoEvent
  )

  test("Refund on non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(Refund({reason: "lost-in-transit"}))
    ->thenError(OrderNotFound)
  )

  test("Refund on placed order returns OrderNotCancelled", () =>
    givenEvents([Placed({customerId: "cust-1", productIds: ["prod-1"]})])
    ->whenCmd(Refund({reason: "customer-changed-mind"}))
    ->thenError(OrderNotCancelled)
  )

  test("Refund on shipped order returns OrderNotCancelled", () =>
    givenEvents([Placed({customerId: "cust-1", productIds: ["prod-1"]}), Shipped])
    ->whenCmd(Refund({reason: "delivered-damaged"}))
    ->thenError(OrderNotCancelled)
  )

  test("Refund on cancelled order produces Refunded", () =>
    givenEvents([
      Placed({customerId: "cust-1", productIds: ["prod-1"]}),
      Cancelled({productIds: ["prod-1"]}),
    ])
    ->whenCmd(Refund({reason: "customer-changed-mind"}))
    ->thenEvent(Refunded({reason: "customer-changed-mind"}))
  )

  test("Refund on already-refunded order produces no events (idempotent)", () =>
    givenEvents([
      Placed({customerId: "cust-1", productIds: ["prod-1"]}),
      Cancelled({productIds: ["prod-1"]}),
      Refunded({reason: "customer-changed-mind"}),
    ])
    ->whenCmd(Refund({reason: "customer-changed-mind"}))
    ->thenNoEvent
  )
})
