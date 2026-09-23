@@reventless.gwt

open Catalog_Examples

describe("RecordProductDemand StateChangeSlice", () => {
  // scenario-id: 5fcdfc28-a6e3-4a0d-b260-997b12ff1a43
  test("first RecordDemand produces ProductDemandRecorded", () =>
    givenEvents([])
    ->whenCmd(RecordDemand({productId: p1, orderId: order1}))
    ->thenEvent(ProductDemandRecorded({productId: p1, orderId: order1}))
  )

  // scenario-id: 1e537de7-cd0a-49a4-8ed8-405a612127c2
  test("RecordDemand for new orderId on existing product produces ProductDemandRecorded", () =>
    givenEvents([ProductDemandRecorded({orderId: order1})])
    ->whenCmd(RecordDemand({productId: p1, orderId: order2}))
    ->thenEvent(ProductDemandRecorded({productId: p1, orderId: order2}))
  )

  // scenario-id: 8662bbac-3e14-49f3-8847-cc1e7bffd940
  test("RecordDemand for already-recorded orderId produces no events (idempotent)", () =>
    givenEvents([ProductDemandRecorded({orderId: order1})])
    ->whenCmd(RecordDemand({productId: p1, orderId: order1}))
    ->thenNoEvent
  )

  // scenario-id: bf35b93f-7da5-4af7-bfcf-3cc063f3c391
  test("RevokeDemand on never-recorded product produces no events (idempotent)", () =>
    givenEvents([])
    ->whenCmd(RevokeDemand({productId: p1, orderId: order1}))
    ->thenNoEvent
  )

  // scenario-id: 8509c790-1d28-444f-976d-eb476d0c5ded
  test(
    "RevokeDemand for unrecorded orderId on existing product produces no events (idempotent)",
    () =>
      givenEvents([ProductDemandRecorded({orderId: order1})])
      ->whenCmd(RevokeDemand({productId: p1, orderId: order2}))
      ->thenNoEvent,
  )

  // scenario-id: 2a4f7844-488c-4722-b8b1-ad7095fdb2e3
  test("RevokeDemand for recorded orderId produces ProductDemandRevoked", () =>
    givenEvents([ProductDemandRecorded({orderId: order1})])
    ->whenCmd(RevokeDemand({productId: p1, orderId: order1}))
    ->thenEvent(ProductDemandRevoked({productId: p1, orderId: order1}))
  )
})
