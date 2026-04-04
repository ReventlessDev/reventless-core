// Categories read model specification.
// Query-side state for product categories.

@@reventless.spec

@schema
type state = {
  name: string,
  archived: bool,
}

open Reventless.ReadModel
let config = config()
let subIdConfig = None
