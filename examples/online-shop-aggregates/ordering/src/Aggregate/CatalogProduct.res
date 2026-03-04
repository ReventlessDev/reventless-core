// CatalogProduct aggregate specification.
// Stores a synced shadow of Catalog products inside Ordering,
// driven by Catalog's ProductsExtensionPoint.

open Reventless
module Id = Id.String

let name = "CatalogProduct"

@schema
type command =
  | Sync({name: string, price: float})
  | UpdatePrice({price: float})

@schema
type event =
  | Synced({name: string, price: float})
  | PriceUpdated({price: float})

@schema
type error = unit // always succeeds — sync is idempotent
