// Orders read model specification.
// Query-side state for customer orders.

open Reventless
module Id = Id.String

@schema
type state = {
  orderId: string,
  customerId: string,
  productIds: array<string>,
  status: string, // "placed" | "shipped" | "cancelled"
}

let name = "Orders"

open Reventless.ReadModel
let config = config()
let subIdConfig = None
