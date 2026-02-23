// Orders read model specification.
// Query-side state for customer orders.

module Id = ReventlessSpec.Id.String

@schema
type state = {
  orderId: string,
  customerId: string,
  productIds: array<string>,
  status: string, // "placed" | "shipped" | "cancelled"
}

let name = "Orders"

open ReventlessSpec.ReadModel
let config = config()
let subIdConfig = None
