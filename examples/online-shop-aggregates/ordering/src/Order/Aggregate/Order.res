// Order aggregate specification.
// A confirmed purchase referencing Product IDs and a CustomerId.

@@reventless.spec

@schema
type command =
  | Place({customerId: string, @ref("AvailableProducts") @noDcbTag productIds: array<string>})
  | @transition(([Orders.Placed]) => Orders.Shipped) Ship
  | @transition(([Orders.Placed]) => Orders.Cancelled) Cancel
  | @transition(([Orders.Cancelled]) => Orders.Refunded) Refund({reason: string})

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
