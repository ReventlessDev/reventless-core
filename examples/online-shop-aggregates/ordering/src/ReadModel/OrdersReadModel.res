// Orders read model specification.
// Query-side state for customer orders.

@@reventless.spec

@schema
type state = {
  customerId: string,
  productIds: array<string>,
  status: string, // "placed" | "shipped" | "cancelled"
}

open Reventless.ReadModel
let config = config()
let subIdConfig = None
