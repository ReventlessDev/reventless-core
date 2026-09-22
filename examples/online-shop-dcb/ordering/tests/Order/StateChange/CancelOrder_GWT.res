@@reventless.gwt

open OrderingExamples

describe("CancelOrder StateChangeSlice", () => {
  // scenario-id: 8ec10480-8490-4004-a83c-1efa3d94695c
  test("non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(CancelOrder({orderId: o1}))
    ->thenError(OrderNotFound)
  )

  // scenario-id: df6a7117-bfed-4393-ae46-a35b13339e32
  test("placed order produces OrderCancelled with productIds carried over", () =>
    givenEvents([OrderPlaced({productIds: [p1, p2]})])
    ->whenCmd(CancelOrder({orderId: o1}))
    ->thenEvent(OrderCancelled({orderId: o1, productIds: [p1, p2]}))
  )

  // scenario-id: e639ee37-866c-45f9-ac7b-d2a902703578
  test("already cancelled order produces no events (idempotent)", () =>
    givenEvents([OrderPlaced({productIds: [p1]}), OrderCancelled])
    ->whenCmd(CancelOrder({orderId: o1}))
    ->thenNoEvent
  )

  // scenario-id: eb8ae949-bd89-4b4c-9b4c-25992727e172
  test("shipped order returns OrderAlreadyShipped", () =>
    givenEvents([OrderPlaced({productIds: [p1]}), OrderShipped])
    ->whenCmd(CancelOrder({orderId: o1}))
    ->thenError(OrderAlreadyShipped)
  )
})
