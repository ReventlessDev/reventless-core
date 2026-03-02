// CatalogProduct aggregate specification.
// Stores a synced shadow of Catalog products inside Ordering,
// driven by Catalog's ProductsExtensionPoint.

open Reventless
module Id = Id.String

let name = "CatalogProduct"

@schema
type command =
  | SyncNewProduct({productId: string, name: string, price: float})
  | UpdateSyncedPrice({productId: string, price: float})

@schema
type event =
  | CatalogProductSynced({productId: string, name: string, price: float})
  | CatalogProductPriceUpdated({productId: string, price: float})

@schema
type error = unit // always succeeds — sync is idempotent
