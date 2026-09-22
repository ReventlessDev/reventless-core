@@reventless.gwt

open CatalogExamples

describe("ProductDemand Behavior", () => {
  // scenario-id: bfe0c68e-f135-447f-9036-c339c9769747
  test("Record on new aggregate produces Recorded", () =>
    givenEvents([])
    ->whenCmd(Record({orderId: order1}))
    ->thenEvent(Recorded({orderId: order1}))
  )

  // scenario-id: 2c698c93-c654-455f-b419-4dc348b7141a
  test("Record with new orderId on existing aggregate produces Recorded", () =>
    givenEvents([Recorded({orderId: order1})])
    ->whenCmd(Record({orderId: order2}))
    ->thenEvent(Recorded({orderId: order2}))
  )

  // scenario-id: 69f95379-c48a-494a-aa45-c371a7086fcd
  test("Record with already-recorded orderId produces no events (idempotent)", () =>
    givenEvents([Recorded({orderId: order1})])
    ->whenCmd(Record({orderId: order1}))
    ->thenNoEvent
  )

  // scenario-id: 5892b683-1237-4480-adba-112df104c227
  test("Revoke on never-recorded aggregate produces no events (idempotent)", () =>
    givenEvents([])
    ->whenCmd(Revoke({orderId: order1}))
    ->thenNoEvent
  )

  // scenario-id: 8d66cbc0-ea4e-4808-bdcd-259a76b84cb0
  test("Revoke of unrecorded orderId on existing aggregate produces no events (idempotent)", () =>
    givenEvents([Recorded({orderId: order1})])
    ->whenCmd(Revoke({orderId: order2}))
    ->thenNoEvent
  )

  // scenario-id: 52fa64d9-2a4e-4d80-9e5d-bed10876aa96
  test("Revoke of recorded orderId produces Revoked", () =>
    givenEvents([Recorded({orderId: order1})])
    ->whenCmd(Revoke({orderId: order1}))
    ->thenEvent(Revoked({orderId: order1}))
  )
})
