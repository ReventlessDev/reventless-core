@@reventless.gwt

describe("ProductDemand Behavior", () => {
  test("Record on new aggregate produces Recorded", () =>
    givenEvents([])
    ->whenCmd(Record({orderId: "order-1"}))
    ->thenEvent(Recorded({orderId: "order-1"}))
  )

  test("Record with new orderId on existing aggregate produces Recorded", () =>
    givenEvents([Recorded({orderId: "order-1"})])
    ->whenCmd(Record({orderId: "order-2"}))
    ->thenEvent(Recorded({orderId: "order-2"}))
  )

  test("Record with already-recorded orderId produces no events (idempotent)", () =>
    givenEvents([Recorded({orderId: "order-1"})])
    ->whenCmd(Record({orderId: "order-1"}))
    ->thenNoEvent
  )

  test("Revoke on never-recorded aggregate produces no events (idempotent)", () =>
    givenEvents([])
    ->whenCmd(Revoke({orderId: "order-1"}))
    ->thenNoEvent
  )

  test("Revoke of unrecorded orderId on existing aggregate produces no events (idempotent)", () =>
    givenEvents([Recorded({orderId: "order-1"})])
    ->whenCmd(Revoke({orderId: "order-2"}))
    ->thenNoEvent
  )

  test("Revoke of recorded orderId produces Revoked", () =>
    givenEvents([Recorded({orderId: "order-1"})])
    ->whenCmd(Revoke({orderId: "order-1"}))
    ->thenEvent(Revoked({orderId: "order-1"}))
  )
})
