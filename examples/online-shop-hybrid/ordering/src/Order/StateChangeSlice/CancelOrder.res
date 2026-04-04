// CancelOrder StateChangeSlice.
// Requires order to exist and not be shipped; idempotent if already cancelled.

@@reventless.spec
@@reventless.dcbTags

type state = {exists: bool, shipped: bool, cancelled: bool, productIds: array<string>}

let initialState = {exists: false, shipped: false, cancelled: false, productIds: []}

@schema
type consumedEvent =
  | OrderPlaced({productIds: array<string>})
  | OrderShipped
  | OrderCancelled

let evolve = (state, event) =>
  switch event {
  | OrderPlaced({productIds}) => {exists: true, shipped: false, cancelled: false, productIds}
  | OrderShipped => {...state, shipped: true}
  | OrderCancelled => {...state, cancelled: true}
  }

@schema
type command = CancelOrder({orderId: string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyShipped

@schema
type event =
  | OrderCancelled({
      orderId: string,
      productIds: array<string>,
    })

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
  }
