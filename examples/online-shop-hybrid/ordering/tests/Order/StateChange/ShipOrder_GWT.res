@@reventless.gwt

let oid = OrderId.make
let cid = CustomerId.make
let pid = CatalogSpec.ProductId.make

describe("ShipOrder StateChangeSlice", () => {
  test("non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(ShipOrder({orderId: oid("o1")}))
    ->thenError(OrderNotFound)
  )

  test("placed order produces OrderShipped", () =>
    givenEvents([OrderPlaced({productIds: [pid("p1")], customerId: cid("c1")})])
    ->whenCmd(ShipOrder({orderId: oid("o1")}))
    ->thenEvent(OrderShipped({orderId: oid("o1"), customerId: cid("c1")}))
  )

  test("already shipped order produces no events (idempotent)", () =>
    givenEvents([OrderPlaced({productIds: [pid("p1")], customerId: cid("c1")}), OrderShipped])
    ->whenCmd(ShipOrder({orderId: oid("o1")}))
    ->thenNoEvent
  )

  test("cancelled order returns OrderAlreadyCancelled", () =>
    givenEvents([OrderPlaced({productIds: [pid("p1")], customerId: cid("c1")}), OrderCancelled])
    ->whenCmd(ShipOrder({orderId: oid("o1")}))
    ->thenError(OrderAlreadyCancelled)
  )

  // The case the slice used to get wrong. It folded `OrderCancelled` without
  // ever hearing `OrderReopened`, so a reopened order stayed cancelled here for
  // good and could never ship again — while `CancelOrder`, which does consume
  // the reopen, happily kept issuing it. Nothing in the declaration was wrong;
  // the two folds simply disagreed, and only running them says so.
  test("reopened order can ship again", () =>
    givenEvents([
      OrderPlaced({productIds: [pid("p1")], customerId: cid("c1")}),
      OrderCancelled,
      OrderReopened,
    ])
    ->whenCmd(ShipOrder({orderId: oid("o1")}))
    ->thenEvent(OrderShipped({orderId: oid("o1"), customerId: cid("c1")}))
  )
})
