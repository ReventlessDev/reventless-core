// Unit tests for Order aggregate behavior.
// Uses the BehaviorTest DSL for pure synchronous testing.

open Order

include ReventlessGwt.Behavior_GWT.Make(Order, OrderBehavior)

describe("OrderBehavior:", () => {
  describe("Place", () => {
    test(
      "on new aggregate produces Placed",
      () =>
        givenEvents([])
        ->whenCmd(
          Place({
            customerId: "cust-1",
            productIds: ["prod-1", "prod-2"],
          }),
        )
        ->thenEvent(
          Placed({
            customerId: "cust-1",
            productIds: ["prod-1", "prod-2"],
          }),
        ),
    )

    test(
      "on existing order returns OrderAlreadyPlaced error",
      () =>
        givenEvents([Placed({customerId: "cust-1", productIds: ["prod-1"]})])
        ->whenCmd(Place({customerId: "cust-1", productIds: ["prod-1"]}))
        ->thenError(OrderAlreadyPlaced),
    )
  })

  describe("Ship", () => {
    test(
      "on non-existent order returns OrderNotFound error",
      () =>
        givenEvents([])
        ->whenCmd(Ship)
        ->thenError(OrderNotFound),
    )

    test(
      "on placed order produces Shipped",
      () =>
        givenEvents([Placed({customerId: "cust-1", productIds: ["prod-1"]})])
        ->whenCmd(Ship)
        ->thenEvent(Shipped),
    )

    test(
      "on shipped order is idempotent (produces no events)",
      () =>
        givenEvents([
          Placed({customerId: "cust-1", productIds: ["prod-1"]}),
          Shipped,
        ])
        ->whenCmd(Ship)
        ->thenNoEvent,
    )

    test(
      "on cancelled order returns OrderAlreadyCancelled error",
      () =>
        givenEvents([
          Placed({customerId: "cust-1", productIds: ["prod-1"]}),
          Cancelled({productIds: ["prod-1"]}),
        ])
        ->whenCmd(Ship)
        ->thenError(OrderAlreadyCancelled),
    )
  })

  describe("Cancel", () => {
    test(
      "on placed order produces Cancelled",
      () =>
        givenEvents([Placed({customerId: "cust-1", productIds: ["prod-1"]})])
        ->whenCmd(Cancel)
        ->thenEvent(Cancelled({productIds: ["prod-1"]})),
    )

    test(
      "on cancelled order is idempotent (produces no events)",
      () =>
        givenEvents([
          Placed({customerId: "cust-1", productIds: ["prod-1"]}),
          Cancelled({productIds: ["prod-1"]}),
        ])
        ->whenCmd(Cancel)
        ->thenNoEvent,
    )

    test(
      "on shipped order returns OrderAlreadyShipped error",
      () =>
        givenEvents([
          Placed({customerId: "cust-1", productIds: ["prod-1"]}),
          Shipped,
        ])
        ->whenCmd(Cancel)
        ->thenError(OrderAlreadyShipped),
    )
  })
})
