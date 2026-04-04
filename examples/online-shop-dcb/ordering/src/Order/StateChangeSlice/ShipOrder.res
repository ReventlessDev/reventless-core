// ShipOrder StateChangeSlice.
// Requires order to exist and not be cancelled; idempotent if already shipped.
@@reventless.spec

type state = {exists: bool, shipped: bool, cancelled: bool}

let initialState = {exists: false, shipped: false, cancelled: false}

@schema
type consumedEvent =
  | OrderPlaced
  | OrderShipped
  | OrderCancelled

let evolve = (state, event) =>
  switch event {
  | OrderPlaced => {exists: true, shipped: false, cancelled: false}
  | OrderShipped => {...state, shipped: true}
  | OrderCancelled => {...state, cancelled: true}
  }

@schema
type command = ShipOrder({orderId: string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyCancelled

@schema
type event = OrderShipped({orderId: string})

let decide = (state, command) =>
  switch command {
  | ShipOrder({orderId: theId}) =>
    if !state.exists {
      Error(OrderNotFound)
    } else if state.cancelled {
      Error(OrderAlreadyCancelled)
    } else if state.shipped {
      Ok([]) // idempotent — already shipped
    } else {
      Ok([OrderShipped({orderId: theId})])
    }
  }
