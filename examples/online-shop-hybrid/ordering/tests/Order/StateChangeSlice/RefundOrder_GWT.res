@@reventless.gwt

describe("RefundOrder StateChangeSlice", () => {
  test("non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(IssueRefund({orderId: "o1", reason: "duplicate"}))
    ->thenError(OrderNotFound)
  )

  test("non-cancelled order returns OrderNotCancelled", () =>
    givenEvents([OrderPlaced])
    ->whenCmd(IssueRefund({orderId: "o1", reason: "duplicate"}))
    ->thenError(OrderNotCancelled)
  )

  test("cancelled order produces RefundIssued", () =>
    givenEvents([OrderPlaced, OrderCancelled])
    ->whenCmd(IssueRefund({orderId: "o1", reason: "duplicate"}))
    ->thenEvent(RefundIssued({orderId: "o1", reason: "duplicate"}))
  )

  test("already refunded order returns RefundAlreadyIssued", () =>
    givenEvents([
      OrderPlaced,
      OrderCancelled,
      RefundIssued({reason: "duplicate"}),
    ])
    ->whenCmd(IssueRefund({orderId: "o1", reason: "again"}))
    ->thenError(RefundAlreadyIssued)
  )
})
