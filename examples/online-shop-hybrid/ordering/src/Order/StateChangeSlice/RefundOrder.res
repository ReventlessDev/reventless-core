// RefundOrder StateChangeSlice.
// Handles internal refund processing — entirely hidden from public API.
// This is an automation/admin-only workflow triggered after cancellation.

@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced
  | OrderCancelled
  | RefundIssued({reason: string})

@schema @noApi
type command = IssueRefund({orderId: string, reason: string})

@schema
type error =
  | OrderNotFound
  | OrderNotCancelled
  | RefundAlreadyIssued

@schema
type event =
  | RefundIssued({
      orderId: string,
      reason: string,
    })
