@@reventless.behavior

type state = {exists: bool, shipped: bool, cancelled: bool}

let initialState = {exists: false, shipped: false, cancelled: false}

let evolve = (state, event) =>
  switch event {
  // productIds is carried only to keep OrderPlaced out of the payload-less
  // filter (so the slice links to Orders); ShipOrder's decision doesn't use it.
  | OrderPlaced(_) => {exists: true, shipped: false, cancelled: false}
  | OrderShipped => {...state, shipped: true}
  | OrderCancelled => {...state, cancelled: true}
  }

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
