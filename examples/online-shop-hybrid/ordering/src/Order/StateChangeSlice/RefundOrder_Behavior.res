@@reventless.behavior

type state = {exists: bool, cancelled: bool, refunded: bool}

let initialState = {exists: false, cancelled: false, refunded: false}

let evolve = (state, event) =>
  switch event {
  | OrderPlaced => {exists: true, cancelled: false, refunded: false}
  | OrderCancelled => {...state, cancelled: true}
  | RefundIssued(_) => {...state, refunded: true}
  }

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
