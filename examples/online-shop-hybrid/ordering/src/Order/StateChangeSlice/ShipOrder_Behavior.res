@@reventless.behavior

// One state at a time, rather than three booleans. The flag triple this
// replaced could represent `shipped && cancelled` — a shape the domain does not
// have and every branch had to avoid by hand. A variant can only hold what the
// fold is actually recording: where the order is now.
type state =
  | NotPlaced
  | Placed
  | Shipped
  | Cancelled

let initialState = NotPlaced

let evolve = (_state, event) =>
  switch event {
  // productIds is carried only to keep OrderPlaced out of the payload-less
  // filter (so the slice links to Orders); ShipOrder's decision doesn't use it.
  | OrderPlaced(_) => Placed
  | OrderShipped => Shipped
  | OrderCancelled => Cancelled
  // A reopened order is placed again. Without this arm the slice never hears
  // that the cancellation was undone, so it keeps refusing on a fact that is no
  // longer true: an order could be reopened and then never shipped, for the
  // rest of its life.
  | OrderReopened => Placed
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotPlaced, ShipOrder(_)) => Error(OrderNotFound)
  | (Cancelled, ShipOrder(_)) => Error(OrderAlreadyCancelled)
  | (Shipped, ShipOrder(_)) => Ok([]) // idempotent — already shipped
  | (Placed, ShipOrder({orderId: theId})) => Ok([OrderShipped({orderId: theId})])
  }
