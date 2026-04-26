@@reventless.behavior

type state = {exists: bool}

let initialState = {exists: false}

let evolve = (_state, event) =>
  switch event {
  | OrderPlaced => {exists: true}
  }

let decide = (state, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productIds}) =>
    if state.exists {
      Error(OrderAlreadyPlaced)
    } else {
      Ok([OrderPlaced({orderId, customerId, productIds})])
    }
  }
