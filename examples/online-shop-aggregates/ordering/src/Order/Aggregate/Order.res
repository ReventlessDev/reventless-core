// Order aggregate specification.
// A confirmed purchase referencing Product IDs and a CustomerId.

@@reventless.spec

@schema
type command =
  | Place({customerId: string, @ref("AvailableProducts") @noDcbTag productIds: array<string>})
  | Ship
  | Cancel
  | Refund({reason: string})

@schema
type event =
  | Placed({customerId: string, productIds: array<string>})
  | Shipped
  | Cancelled({productIds: array<string>})
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
  | Place(_) => Unrestricted
  | Ship => Moves([Orders.Placed], Orders.Shipped)
  | Cancel => Moves([Orders.Placed], Orders.Cancelled)
  | Refund(_) => Moves([Orders.Cancelled], Orders.Refunded)
  }
}
