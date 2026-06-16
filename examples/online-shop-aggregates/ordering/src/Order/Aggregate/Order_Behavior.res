// Order aggregate behavior.
// Implements the lifecycle for placing, shipping, cancelling, and refunding orders.

@@reventless.behavior

@schema
type state =
  | NotCreated
  | Placed({customerId: string, productIds: array<string>})
  | Shipped
  | Cancelled
  | Refunded

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Order.Placed({customerId, productIds})) => Placed({customerId, productIds})
  | (Placed(_), Order.Placed({customerId, productIds})) => Placed({customerId, productIds})
  | (Placed(_), Order.Shipped) => Shipped
  | (Placed(_), Order.Cancelled(_)) => Cancelled
  | (Cancelled, Order.Refunded(_)) => Refunded
  | (Shipped, _) => state
  | (Cancelled, _) => state
  | (Refunded, _) => state
  | (NotCreated, _) => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Place({customerId, productIds})) =>
    Ok([Order.Placed({customerId, productIds})])
  | (NotCreated, Ship) => Error(OrderNotFound)
  | (NotCreated, Cancel) => Error(OrderNotFound)
  | (NotCreated, Refund(_)) => Error(OrderNotFound)
  | (Placed(_), Place(_)) => Error(OrderAlreadyPlaced)
  | (Placed(_), Ship) => Ok([Order.Shipped])
  | (Placed({productIds}), Cancel) => Ok([Order.Cancelled({productIds: productIds})])
  | (Placed(_), Refund(_)) => Error(OrderNotCancelled)
  | (Shipped, Place(_)) => Error(OrderAlreadyShipped)
  | (Shipped, Ship) => Ok([]) // idempotent
  | (Shipped, Cancel) => Error(OrderAlreadyShipped)
  | (Shipped, Refund(_)) => Error(OrderNotCancelled)
  | (Cancelled, Place(_)) => Error(OrderAlreadyCancelled)
  | (Cancelled, Ship) => Error(OrderAlreadyCancelled)
  | (Cancelled, Cancel) => Ok([]) // idempotent
  | (Cancelled, Refund({reason})) => Ok([Order.Refunded({reason: reason})])
  | (Refunded, Place(_)) => Error(OrderAlreadyRefunded)
  | (Refunded, Ship) => Error(OrderAlreadyRefunded)
  | (Refunded, Cancel) => Error(OrderAlreadyRefunded)
  | (Refunded, Refund(_)) => Ok([]) // idempotent
  }
