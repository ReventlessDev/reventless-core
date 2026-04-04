// PlaceOrder StateChangeSlice.
// Handles the PlaceOrder command; rejects duplicate placement.
@@reventless.spec

type state = {exists: bool}

let initialState = {exists: false}

@schema
type consumedEvent =
  | OrderPlaced

let evolve = (_state, event) =>
  switch event {
  | OrderPlaced => {exists: true}
  }

@schema
type command =
  | PlaceOrder({
      orderId: string,
      customerId: string,
      productIds: array<string>,
    })

@schema
type error = OrderAlreadyPlaced

@schema
type event =
  | OrderPlaced({
      orderId: string,
      customerId: string,
      productIds: array<string>,
    })

let decide = (state, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productIds}) =>
    if state.exists {
      Error(OrderAlreadyPlaced)
    } else {
      Ok([OrderPlaced({orderId, customerId, productIds})])
    }
  }
