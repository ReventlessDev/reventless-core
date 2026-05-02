@@reventless.gwt

describe("RecordProductDemand StateChangeSlice", () => {
  test("first RecordDemand produces ProductDemandRecorded", () =>
    givenEvents([])
    ->whenCmd(RecordDemand({productId: "p1", orderId: "order-1"}))
    ->thenEvent(ProductDemandRecorded({productId: "p1", orderId: "order-1"}))
  )

  test("RecordDemand for new orderId produces ProductDemandRecorded", () =>
    givenEvents([ProductDemandRecorded({orderId: "order-1"})])
    ->whenCmd(RecordDemand({productId: "p1", orderId: "order-2"}))
    ->thenEvent(ProductDemandRecorded({productId: "p1", orderId: "order-2"}))
  )

  test("RecordDemand for already-recorded orderId produces no events (idempotent)", () =>
    givenEvents([ProductDemandRecorded({orderId: "order-1"})])
    ->whenCmd(RecordDemand({productId: "p1", orderId: "order-1"}))
    ->thenNoEvent
  )

  test("RevokeDemand on never-recorded product produces no events (idempotent)", () =>
    givenEvents([])
    ->whenCmd(RevokeDemand({productId: "p1", orderId: "order-1"}))
    ->thenNoEvent
  )

  test("RevokeDemand for unrecorded orderId produces no events (idempotent)", () =>
    givenEvents([ProductDemandRecorded({orderId: "order-1"})])
    ->whenCmd(RevokeDemand({productId: "p1", orderId: "order-2"}))
    ->thenNoEvent
  )

  test("RevokeDemand for recorded orderId produces ProductDemandRevoked", () =>
    givenEvents([ProductDemandRecorded({orderId: "order-1"})])
    ->whenCmd(RevokeDemand({productId: "p1", orderId: "order-1"}))
    ->thenEvent(ProductDemandRevoked({productId: "p1", orderId: "order-1"}))
  )
})
