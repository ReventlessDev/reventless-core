// Customers read model specification.
// Query-side state for registered customers.

open Reventless
module Id = Id.String

@schema
type state = {
  customerId: string,
  email: string,
  address: string,
  deactivated: bool,
}

let name = "Customers"
let moduleUrl: string = %raw(`import.meta.url`)

open Reventless.ReadModel
let config = config()
let subIdConfig = None
