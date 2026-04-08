// CancelOrder StateChangeSlice.
// Requires order to exist and not be shipped; idempotent if already cancelled.

@@reventless.spec

type state = {exists: bool, shipped: bool, cancelled: bool, productId: array<string>}

let initialState = {exists: false, shipped: false, cancelled: false, productId: []}

@schema
type consumedEvent =
  | OrderPlaced({productId: array<string>})
  | OrderShipped
  | OrderCancelled
  | OrderReopened

let evolve = (state, event) =>
  switch event {
  | OrderPlaced({productId}) => {exists: true, shipped: false, cancelled: false, productId}
  | OrderShipped => {...state, shipped: true}
  | OrderCancelled => {...state, cancelled: true}
  | OrderReopened => {...state, cancelled: false}
  }

@schema
type command =
  | CancelOrder({orderId: string})
  | @noApi ReopenOrder({orderId: string})  // Internal: admin/automation only

@schema
type error =
  | OrderNotFound
  | OrderAlreadyShipped

@schema
type event =
  | OrderCancelled({
      orderId: string,
      productId: array<string>,
    })
  | OrderReopened({orderId: string})

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
