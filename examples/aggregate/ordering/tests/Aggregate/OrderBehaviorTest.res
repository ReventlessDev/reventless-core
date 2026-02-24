// Unit tests for Order aggregate behavior.
// Uses the BehaviorTest DSL for pure synchronous testing.

open Order

include ReventlessInMemory.BehaviorTest.Make(Order, OrderBehavior)

describe("OrderBehavior:", () => {
  describe("PlaceOrder", () => {
    test(
      "on new aggregate produces OrderPlaced",
      () =>
        givenEvents([])
        ->whenCmd(
          PlaceOrder({
            orderId: "ord-1",
            customerId: "cust-1",
            productIds: ["prod-1", "prod-2"],
          }),
        )
        ->thenEvent(
          OrderPlaced({
            orderId: "ord-1",
            customerId: "cust-1",
            productIds: ["prod-1", "prod-2"],
          }),
        ),
    )

    test(
      "on existing order returns OrderAlreadyPlaced error",
      () =>
        givenEvents([OrderPlaced({orderId: "ord-1", customerId: "cust-1", productIds: ["prod-1"]})])
        ->whenCmd(PlaceOrder({orderId: "ord-1", customerId: "cust-1", productIds: ["prod-1"]}))
        ->thenError(OrderAlreadyPlaced),
    )
  })

  describe("ShipOrder", () => {
    test(
      "on non-existent order returns OrderNotFound error",
      () =>
        givenEvents([])
        ->whenCmd(ShipOrder({orderId: "ord-1"}))
        ->thenError(OrderNotFound),
    )

    test(
      "on placed order produces OrderShipped",
      () =>
        givenEvents([OrderPlaced({orderId: "ord-1", customerId: "cust-1", productIds: ["prod-1"]})])
        ->whenCmd(ShipOrder({orderId: "ord-1"}))
        ->thenEvent(OrderShipped({orderId: "ord-1"})),
    )

    test(
      "on shipped order is idempotent (produces no events)",
      () =>
        givenEvents([
          OrderPlaced({orderId: "ord-1", customerId: "cust-1", productIds: ["prod-1"]}),
          OrderShipped({orderId: "ord-1"}),
        ])
        ->whenCmd(ShipOrder({orderId: "ord-1"}))
        ->thenNoEvent,
    )

    test(
      "on cancelled order returns OrderAlreadyCancelled error",
      () =>
        givenEvents([
          OrderPlaced({orderId: "ord-1", customerId: "cust-1", productIds: ["prod-1"]}),
          OrderCancelled({orderId: "ord-1"}),
        ])
        ->whenCmd(ShipOrder({orderId: "ord-1"}))
        ->thenError(OrderAlreadyCancelled),
    )
  })

  describe("CancelOrder", () => {
    test(
      "on placed order produces OrderCancelled",
      () =>
        givenEvents([OrderPlaced({orderId: "ord-1", customerId: "cust-1", productIds: ["prod-1"]})])
        ->whenCmd(CancelOrder({orderId: "ord-1"}))
        ->thenEvent(OrderCancelled({orderId: "ord-1"})),
    )

    test(
      "on cancelled order is idempotent (produces no events)",
      () =>
        givenEvents([
          OrderPlaced({orderId: "ord-1", customerId: "cust-1", productIds: ["prod-1"]}),
          OrderCancelled({orderId: "ord-1"}),
        ])
        ->whenCmd(CancelOrder({orderId: "ord-1"}))
        ->thenNoEvent,
    )

    test(
      "on shipped order returns OrderAlreadyShipped error",
      () =>
        givenEvents([
          OrderPlaced({orderId: "ord-1", customerId: "cust-1", productIds: ["prod-1"]}),
          OrderShipped({orderId: "ord-1"}),
        ])
        ->whenCmd(CancelOrder({orderId: "ord-1"}))
        ->thenError(OrderAlreadyShipped),
    )
  })
})
