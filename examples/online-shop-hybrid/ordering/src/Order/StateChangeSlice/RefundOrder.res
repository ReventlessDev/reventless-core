// RefundOrder StateChangeSlice.
// Handles internal refund processing — entirely hidden from public API.
// This is an automation/admin-only workflow triggered after cancellation.

@@reventless.spec

type state = {exists: bool, cancelled: bool, refunded: bool}

let initialState = {exists: false, cancelled: false, refunded: false}

@schema
type consumedEvent =
  | OrderPlaced
  | OrderCancelled
  | RefundIssued({reason: string})

let evolve = (state, event) =>
  switch event {
  | OrderPlaced => {exists: true, cancelled: false, refunded: false}
  | OrderCancelled => {...state, cancelled: true}
  | RefundIssued(_) => {...state, refunded: true}
  }

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

let decide = (state, command) =>
  switch command {
  | IssueRefund({orderId, reason}) =>
    if !state.exists {
      Error(OrderNotFound)
    } else if !state.cancelled {
      Error(OrderNotCancelled)
    } else if state.refunded {
      Error(RefundAlreadyIssued)
    } else {
      Ok([RefundIssued({orderId, reason})])
    }
  }
