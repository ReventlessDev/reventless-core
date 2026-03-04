// Order aggregate specification.
// A confirmed purchase referencing Product IDs and a CustomerId.

open Reventless
module Id = Id.String

let name = "Order"

@schema
type command =
  | Place({customerId: string, productIds: array<string>})
  | Ship
  | Cancel

@schema
type event =
  | Placed({customerId: string, productIds: array<string>})
  | Shipped
  | Cancelled({productIds: array<string>})

@schema
type error =
  | OrderAlreadyPlaced
  | OrderNotFound
  | OrderAlreadyShipped
  | OrderAlreadyCancelled
