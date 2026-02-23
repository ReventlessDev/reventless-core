// Products read model specification.
// Query-side state for product listings.

module Id = ReventlessSpec.Id.String

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
