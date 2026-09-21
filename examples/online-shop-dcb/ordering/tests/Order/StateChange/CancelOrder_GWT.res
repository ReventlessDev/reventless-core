@@reventless.gwt

let oid = OrderId.make
let pid = CatalogSpec.ProductId.make

describe("CancelOrder StateChangeSlice", () => {
  test("non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(CancelOrder({orderId: oid("o1")}))
    ->thenError(OrderNotFound)
  )

  test("placed order produces OrderCancelled with productIds carried over", () =>
    givenEvents([OrderPlaced({productIds: [pid("p1"), pid("p2")]})])
    ->whenCmd(CancelOrder({orderId: oid("o1")}))
    ->thenEvent(OrderCancelled({orderId: oid("o1"), productIds: [pid("p1"), pid("p2")]}))
  )

  test("already cancelled order produces no events (idempotent)", () =>
    givenEvents([OrderPlaced({productIds: [pid("p1")]}), OrderCancelled])
    ->whenCmd(CancelOrder({orderId: oid("o1")}))
    ->thenNoEvent
  )

  test("shipped order returns OrderAlreadyShipped", () =>
    givenEvents([OrderPlaced({productIds: [pid("p1")]}), OrderShipped])
    ->whenCmd(CancelOrder({orderId: oid("o1")}))
    ->thenError(OrderAlreadyShipped)
  )
})
