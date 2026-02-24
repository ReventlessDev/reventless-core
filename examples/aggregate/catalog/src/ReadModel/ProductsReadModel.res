// Products read model specification.
// Query-side state for product listings.

open ReventlessSpec
module Id = Id.String

@schema
type state = {
  productId: string,
  name: string,
  description: string,
  price: float,
}

let name = "Products"

open ReventlessSpec.ReadModel
let config = config()
let subIdConfig = None
