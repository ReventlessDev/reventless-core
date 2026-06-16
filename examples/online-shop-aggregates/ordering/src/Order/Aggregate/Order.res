// Order aggregate specification.
// A confirmed purchase referencing Product IDs and a CustomerId.

@@reventless.spec

@schema
type command =
  | Place({customerId: string, productIds: array<string>})
  | @allowedStates([Orders.Placed]) Ship
  | @allowedStates([Orders.Placed]) Cancel
  | @allowedStates([Orders.Cancelled]) Refund({reason: string})

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
