// Order aggregate specification.
// A confirmed purchase referencing Product IDs and a CustomerId.

@@reventless.spec

module Id = OrderId

@schema
type command =
  // Both references are derived from the types: AvailableProducts is the one view
  // here keyed by ProductId, and Customers the one keyed by CustomerId.
  | Place({customerId: CustomerId.t, productIds: array<CatalogSpec.ProductId.t>})
  | Ship
  | Cancel
  | Refund({reason: string})

@schema
type event =
  | Placed({customerId: CustomerId.t, productIds: array<CatalogSpec.ProductId.t>})
  | Shipped
  | Cancelled({productIds: array<CatalogSpec.ProductId.t>})
  | Refunded({reason: string})

@schema
type error =
  | OrderAlreadyPlaced
  | OrderNotFound
  | OrderAlreadyShipped
  | OrderAlreadyCancelled
  | OrderNotCancelled
  | OrderAlreadyRefunded

// `Place` brings the row into existence, so it names no from-state; the read
// model derives the status it lands in.
type lifecycleState = Orders.lifecycle

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  // Brings the row into existence, so there is no state it could come from.
  // Not `Unrestricted`: the scenarios show it inert on an order already placed,
  // shipped or cancelled, which is the opposite of legal in every state.
  | Place(_) => Creates(Orders.Placed)
  | Ship => Moves([Orders.Placed], Orders.Shipped)
  | Cancel => Moves([Orders.Placed], Orders.Cancelled)
  | Refund(_) => Moves([Orders.Cancelled], Orders.Refunded)
  }
}
