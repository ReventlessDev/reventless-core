@@reventless.gwt

open CatalogExamples

describe("RecordProductDemand StateChangeSlice", () => {
  // scenario-id: ba32b5fd-dd0d-43cb-86f1-9fa547d90ac8
  test("first RecordDemand produces ProductDemandRecorded", () =>
    givenEvents([])
    ->whenCmd(RecordDemand({productId: p1, orderId: order1}))
    ->thenEvent(ProductDemandRecorded({productId: p1, orderId: order1}))
  )

  // scenario-id: 00c2ff52-dd54-4da5-a54c-61d3c565ca39
  test("RecordDemand for new orderId produces ProductDemandRecorded", () =>
    givenEvents([ProductDemandRecorded({orderId: order1})])
    ->whenCmd(RecordDemand({productId: p1, orderId: order2}))
    ->thenEvent(ProductDemandRecorded({productId: p1, orderId: order2}))
  )

  // scenario-id: f0ed8178-430d-43a1-a035-a23d0d9011d9
  test("RecordDemand for already-recorded orderId produces no events (idempotent)", () =>
    givenEvents([ProductDemandRecorded({orderId: order1})])
    ->whenCmd(RecordDemand({productId: p1, orderId: order1}))
    ->thenNoEvent
  )

  // scenario-id: 98a7d086-e01a-4098-8792-e1885717f074
  test("RevokeDemand on never-recorded product produces no events (idempotent)", () =>
    givenEvents([])
    ->whenCmd(RevokeDemand({productId: p1, orderId: order1}))
    ->thenNoEvent
  )

  // scenario-id: 3ba5368b-3bbc-4b20-b23b-5bf146aa8163
  test("RevokeDemand for unrecorded orderId produces no events (idempotent)", () =>
    givenEvents([ProductDemandRecorded({orderId: order1})])
    ->whenCmd(RevokeDemand({productId: p1, orderId: order2}))
    ->thenNoEvent
  )

  // scenario-id: 2738d3f1-79ff-4f67-89ba-9a2626b804b7
  test("RevokeDemand for recorded orderId produces ProductDemandRevoked", () =>
    givenEvents([ProductDemandRecorded({orderId: order1})])
    ->whenCmd(RevokeDemand({productId: p1, orderId: order1}))
    ->thenEvent(ProductDemandRevoked({productId: p1, orderId: order1}))
  )
})
