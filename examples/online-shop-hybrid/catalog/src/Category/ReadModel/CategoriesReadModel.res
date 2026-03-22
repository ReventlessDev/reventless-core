// Categories read model specification.
// Query-side state for product categories.

open Reventless
module Id = Id.String

@schema
type state = {
  categoryId: string,
  name: string,
  archived: bool,
}

let name = "Categories"
let moduleUrl: string = %raw(`import.meta.url`)

open Reventless.ReadModel
let config = config()
let subIdConfig = None
