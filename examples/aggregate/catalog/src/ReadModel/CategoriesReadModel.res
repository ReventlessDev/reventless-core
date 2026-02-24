// Categories read model specification.
// Query-side state for product categories.

open ReventlessSpec
module Id = Id.String

@schema
type state = {
  categoryId: string,
  name: string,
  archived: bool,
}

let name = "Categories"

open ReventlessSpec.ReadModel
let config = config()
let subIdConfig = None
