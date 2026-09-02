@@reventless.behavior

// One state at a time, rather than three booleans. The flag triple this
// replaced could represent `shipped && cancelled` — a shape the domain does not
// have and every branch had to avoid by hand. A variant can only hold what the
// fold is actually recording: where the order is now.
type lifecycle =
  | NotPlaced
  | Placed
  | Shipped
  | Cancelled

// `customerId` rides alongside because the shipment event carries it back out,
// the way `CancelOrder` carries `productIds` out for restocking. It is never
// read by `decide` — it is a value passing through the fold, not a fact this
// slice reasons about.
type state = {lifecycle: lifecycle, customerId: string}

let initialState = {lifecycle: NotPlaced, customerId: ""}

let evolve = (state, event) =>
  switch event {
  // productIds is carried only to keep OrderPlaced out of the payload-less
  // filter (so the slice links to Orders); neither field is decided with.
  | OrderPlaced({customerId}) => {lifecycle: Placed, customerId}
  | OrderShipped => {...state, lifecycle: Shipped}
  | OrderCancelled => {...state, lifecycle: Cancelled}
  // A reopened order is placed again. Without this arm the slice never hears
  // that the cancellation was undone, so it keeps refusing on a fact that is no
  // longer true: an order could be reopened and then never shipped, for the
  // rest of its life.
  | OrderReopened => {...state, lifecycle: Placed}
  }

let decide = (state, command) =>
  switch (state.lifecycle, command) {
  | (NotPlaced, ShipOrder(_)) => Error(OrderNotFound)
  | (Cancelled, ShipOrder(_)) => Error(OrderAlreadyCancelled)
  | (Shipped, ShipOrder(_)) => Ok([]) // idempotent — already shipped
  | (Placed, ShipOrder({orderId: theId})) =>
    Ok([OrderShipped({orderId: theId, customerId: state.customerId})])
  }
