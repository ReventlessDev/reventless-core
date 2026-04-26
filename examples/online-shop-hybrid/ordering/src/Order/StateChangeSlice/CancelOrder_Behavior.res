@@reventless.behavior

type state = {exists: bool, shipped: bool, cancelled: bool, productId: array<string>}

let initialState = {exists: false, shipped: false, cancelled: false, productId: []}

let evolve = (state, event) =>
  switch event {
  | OrderPlaced({productId}) => {exists: true, shipped: false, cancelled: false, productId}
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
      Ok([OrderCancelled({orderId: theId, productId: state.productId})])
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
