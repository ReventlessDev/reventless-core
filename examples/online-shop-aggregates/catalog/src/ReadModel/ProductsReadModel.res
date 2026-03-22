// Products read model specification.
// Query-side state for product listings.

open Reventless
module Id = Id.String

@schema
type state = {
  name: string,
  description: string,
  price: float,
}

let name = "Products"
let moduleUrl: string = %raw(`import.meta.url`)

open Reventless.ReadModel
let config = config()
let subIdConfig = None
