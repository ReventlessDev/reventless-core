// Products read model specification.
// Query-side state for product listings.

@@reventless.spec

@schema
type state = {
  name: string,
  description: string,
  price: float,
}

open Reventless.ReadModel
let config = config()
let subIdConfig = None
