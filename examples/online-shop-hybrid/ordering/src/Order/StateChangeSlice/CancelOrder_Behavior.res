@@reventless.behavior

type state = {exists: bool, shipped: bool, cancelled: bool, productIds: array<string>}

let initialState = {exists: false, shipped: false, cancelled: false, productIds: []}

let evolve = (state, event) =>
  switch event {
  | OrderPlaced({productIds}) => {exists: true, shipped: false, cancelled: false, productIds}
  | OrderShipped => {...state, shipped: true}
  | OrderCancelled => {...state, cancelled: true}
  | OrderReopened => {...state, cancelled: false}
  }

let decide = (state, command) =>
  switch command {
  | CancelOrder({orderId: theId}) =>
    if !state.exists {
      Error(OrderNotFound)
    } else if state.shipped {
      Error(OrderAlreadyShipped)
    } else if state.cancelled {
      Ok([]) // idempotent — already cancelled
    } else {
      Ok([OrderCancelled({orderId: theId, productIds: state.productIds})])
    }
  | ReopenOrder({orderId: theId}) =>
    if !state.exists {
      Error(OrderNotFound)
    } else if !state.cancelled {
      Ok([]) // idempotent — not cancelled
    } else {
      Ok([OrderReopened({orderId: theId})])
    }
  }
