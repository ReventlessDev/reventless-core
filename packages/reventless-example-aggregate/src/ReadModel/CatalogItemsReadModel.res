// CatalogItem read model specification.
// Defines the query-side state for catalog items.

module Id = ReventlessSpec.Id.String

@schema
type state = {
  itemId: string,
  name: string,
  description: string,
  archived: bool,
}

let name = "CatalogItems"

open ReventlessSpec.ReadModel
let config = config()
let subIdConfig = None
