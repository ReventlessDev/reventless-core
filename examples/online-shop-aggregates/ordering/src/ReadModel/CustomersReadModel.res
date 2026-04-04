// Customers read model specification.
// Query-side state for registered customers.

@@reventless.spec

@schema
type state = {
  email: string,
  address: string,
  deactivated: bool,
}

open Reventless.ReadModel
let config = config()
let subIdConfig = None
