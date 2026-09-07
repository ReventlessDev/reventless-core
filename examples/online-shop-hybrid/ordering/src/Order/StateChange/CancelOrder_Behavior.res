@@reventless.behavior

// Where the order is, as one value rather than a pair of flags that could
// represent `shipped && cancelled`. `productIds` rides alongside because the
// cancellation event carries them back out for restocking.
type lifecycle =
  | NotPlaced
  | Placed
  | Shipped
  | Cancelled

type state = {lifecycle: lifecycle, productIds: array<string>}

let initialState = {lifecycle: NotPlaced, productIds: []}

let evolve = (state, event) =>
  switch event {
  | OrderPlaced({productIds}) => {lifecycle: Placed, productIds}
  | OrderShipped => {...state, lifecycle: Shipped}
  | OrderCancelled => {...state, lifecycle: Cancelled}
  | OrderReopened => {...state, lifecycle: Placed}
  }

let decide = (state, command) =>
  switch (state.lifecycle, command) {
  | (NotPlaced, CancelOrder(_)) => Error(OrderNotFound)
  | (Shipped, CancelOrder(_)) => Error(OrderAlreadyShipped)
  | (Cancelled, CancelOrder(_)) => Ok([]) // idempotent — already cancelled
  | (Placed, CancelOrder({orderId: theId})) =>
    Ok([OrderCancelled({orderId: theId, productIds: state.productIds})])

  | (NotPlaced, ReopenOrder(_)) => Error(OrderNotFound)
  | (Placed, ReopenOrder(_)) => Ok([]) // idempotent — already open
  // A shipped order is not a cancelled one, and reopening it is not a repeat of
  // anything: accepting it silently told the caller their request had been
  // honoured while the order stayed shipped.
  | (Shipped, ReopenOrder(_)) => Error(OrderAlreadyShipped)
  | (Cancelled, ReopenOrder({orderId: theId})) => Ok([OrderReopened({orderId: theId})])
  }
