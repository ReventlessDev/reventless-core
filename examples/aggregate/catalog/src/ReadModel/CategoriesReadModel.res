// Categories read model specification.
// Query-side state for product categories.

module Id = ReventlessSpec.Id.String

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
