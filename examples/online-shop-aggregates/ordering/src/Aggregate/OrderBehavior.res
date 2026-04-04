// Order aggregate behavior.
// Implements the lifecycle for placing, shipping, and cancelling orders.

@@reventless.behavior

@schema
type state =
  | NotCreated
  | Placed({customerId: string, productIds: array<string>})
  | Shipped
  | Cancelled

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Order.Placed({customerId, productIds})) => Placed({customerId, productIds})
  | (Placed(_), Order.Placed({customerId, productIds})) => Placed({customerId, productIds})
  | (Placed(_), Order.Shipped) => Shipped
  | (Placed(_), Order.Cancelled(_)) => Cancelled
  | (Shipped, _) => state
  | (Cancelled, _) => state
  | (NotCreated, _) => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Place({customerId, productIds})) =>
    Ok([Order.Placed({customerId, productIds})])
  | (NotCreated, Ship) => Error(OrderNotFound)
  | (NotCreated, Cancel) => Error(OrderNotFound)
  | (Placed(_), Place(_)) => Error(OrderAlreadyPlaced)
  | (Placed(_), Ship) => Ok([Order.Shipped])
  | (Placed({productIds}), Cancel) => Ok([Order.Cancelled({productIds: productIds})])
  | (Shipped, Place(_)) => Error(OrderAlreadyShipped)
  | (Shipped, Ship) => Ok([]) // idempotent
  | (Shipped, Cancel) => Error(OrderAlreadyShipped)
  | (Cancelled, Place(_)) => Error(OrderAlreadyCancelled)
  | (Cancelled, Ship) => Error(OrderAlreadyCancelled)
  | (Cancelled, Cancel) => Ok([]) // idempotent
  }
