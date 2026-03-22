// Orders read model specification.
// Query-side state for customer orders.

open Reventless
module Id = Id.String

@schema
type state = {
  customerId: string,
  productIds: array<string>,
  status: string, // "placed" | "shipped" | "cancelled"
}

let name = "Orders"
let moduleUrl: string = %raw(`import.meta.url`)

open Reventless.ReadModel
let config = config()
let subIdConfig = None
