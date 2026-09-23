@@reventless.gwt

open Ordering_Examples

describe("CancelOrder StateChangeSlice", () => {
  // scenario-id: a6df99d9-e2c5-45f3-b436-e4d67f560254
  test("non-existent order returns OrderNotFound for CancelOrder", () =>
    givenEvents([])
    ->whenCmd(CancelOrder({orderId: o1}))
    ->thenError(OrderNotFound)
  )

  // scenario-id: 44e2fd1b-d3da-4581-b102-0ccb47e004eb
  test("placed order produces OrderCancelled with productIds carried over", () =>
    givenEvents([OrderPlaced({productIds: [p1, p2]})])
    ->whenCmd(CancelOrder({orderId: o1}))
    ->thenEvent(OrderCancelled({orderId: o1, productIds: [p1, p2]}))
  )

  // scenario-id: 36e7a929-73a3-48ad-96bf-98265877dd9f
  test("already cancelled order produces no events for CancelOrder (idempotent)", () =>
    givenEvents([OrderPlaced({productIds: [p1]}), OrderCancelled])
    ->whenCmd(CancelOrder({orderId: o1}))
    ->thenNoEvent
  )

  // scenario-id: a8adfaaf-2a97-487d-b80b-34b2e79a621d
  test("shipped order returns OrderAlreadyShipped for CancelOrder", () =>
    givenEvents([OrderPlaced({productIds: [p1]}), OrderShipped])
    ->whenCmd(CancelOrder({orderId: o1}))
    ->thenError(OrderAlreadyShipped)
  )

  // scenario-id: da5c2d1d-adaf-412c-ba71-293158b29841
  test("ReopenOrder on cancelled order produces OrderReopened", () =>
    givenEvents([OrderPlaced({productIds: [p1]}), OrderCancelled])
    ->whenCmd(ReopenOrder({orderId: o1}))
    ->thenEvent(OrderReopened({orderId: o1}))
  )

  // scenario-id: edebec12-a5ec-4f71-a1fc-f1db65108db9
  test("ReopenOrder on a placed order produces no events (idempotent)", () =>
    givenEvents([OrderPlaced({productIds: [p1]})])
    ->whenCmd(ReopenOrder({orderId: o1}))
    ->thenNoEvent
  )

  // A shipped order is not a cancelled one, so reopening it is not a repeat of
  // anything. Accepting it silently reported success while the order stayed
  // shipped — the case no test covered, which is how it survived.
  // scenario-id: 96bdee04-7518-4297-81f5-7242a0cffa9f
  test("ReopenOrder on a shipped order returns OrderAlreadyShipped", () =>
    givenEvents([OrderPlaced({productIds: [p1]}), OrderShipped])
    ->whenCmd(ReopenOrder({orderId: o1}))
    ->thenError(OrderAlreadyShipped)
  )

  // scenario-id: 771c1bec-114e-4a36-9441-99301a3d0e02
  test("ReopenOrder on non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(ReopenOrder({orderId: o1}))
    ->thenError(OrderNotFound)
  )
})
