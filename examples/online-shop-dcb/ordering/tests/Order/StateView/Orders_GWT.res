@@reventless.gwt

let cid = CustomerId.make
let oid = OrderId.make
let pid = CatalogSpec.ProductId.make

describe("Orders StateViewSlice", () => {
  test("OrderPlaced creates a row with status Placed", () =>
    givenEvents([])
    ->whenEvent(
      OrderPlaced({orderId: oid("o1"), customerId: cid("c1"), productIds: [pid("p1"), pid("p2")]}),
    )
    ->thenStateWithId(
      "o1",
      {
        orderId: oid("o1"),
        customerId: cid("c1"),
        productIds: [pid("p1"), pid("p2")],
        lifecycle: Placed,
      },
    )
  )

  test("OrderShipped updates status to Shipped", () =>
    givenEvents([OrderPlaced({orderId: oid("o1"), customerId: cid("c1"), productIds: [pid("p1")]})])
    ->whenEvent(OrderShipped({orderId: oid("o1")}))
    ->thenStateWithId(
      "o1",
      {orderId: oid("o1"), customerId: cid("c1"), productIds: [pid("p1")], lifecycle: Shipped},
    )
  )

  test("OrderCancelled updates status to Cancelled", () =>
    givenEvents([OrderPlaced({orderId: oid("o1"), customerId: cid("c1"), productIds: [pid("p1")]})])
    ->whenEvent(OrderCancelled({orderId: oid("o1")}))
    ->thenStateWithId(
      "o1",
      {orderId: oid("o1"), customerId: cid("c1"), productIds: [pid("p1")], lifecycle: Cancelled},
    )
  )
})
