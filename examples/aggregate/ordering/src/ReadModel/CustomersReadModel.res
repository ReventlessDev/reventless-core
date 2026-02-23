// Customers read model specification.
// Query-side state for registered customers.

module Id = ReventlessSpec.Id.String

@schema
type state = {
  customerId: string,
  email: string,
  address: string,
  deactivated: bool,
}

let name = "Customers"

open ReventlessSpec.ReadModel
let config = config()
let subIdConfig = None
