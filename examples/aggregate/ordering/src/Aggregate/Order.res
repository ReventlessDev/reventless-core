// Order aggregate specification.
// A confirmed purchase referencing Product IDs and a CustomerId.

open Reventless
module Id = Id.String

let name = "Order"

@schema
type command =
  | PlaceOrder({orderId: string, customerId: string, productIds: array<string>})
  | ShipOrder({orderId: string})
  | CancelOrder({orderId: string})

@schema
type event =
  | OrderPlaced({orderId: string, customerId: string, productIds: array<string>})
  | OrderShipped({orderId: string})
  | OrderCancelled({orderId: string, productIds: array<string>})

@schema
type error =
  | OrderAlreadyPlaced
  | OrderNotFound
  | OrderAlreadyShipped
  | OrderAlreadyCancelled
