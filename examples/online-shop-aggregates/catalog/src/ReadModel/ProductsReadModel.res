// Products read model specification.
// Query-side state for product listings.

open Reventless
module Id = Id.String

@schema
type state = {
  productId: string,
  name: string,
  description: string,
  price: float,
}

let name = "Products"

open Reventless.ReadModel
let config = config()
let subIdConfig = None
