// SyncCatalogProduct StateChangeSlice.
// Maintains a local shadow of Catalog products inside the Ordering DCB event log.

open Reventless
open OrderingEventLog

let name = "SyncCatalogProduct"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = OrderingEventLog

@schema
type command =
  | SyncNewProduct({productId: @s.matches(DcbTag.string) string, name: string, price: float})
  | ChangeSyncedPrice({productId: @s.matches(DcbTag.string) string, price: float})

@schema
type error = unit // always succeeds — sync is idempotent

type state = {name: string, price: float}
let initialState = {name: "", price: 0.0}

let evolve = (state, event) =>
  switch event {
  | CatalogProductSynced({name, price}) => {name, price}
  | CatalogProductPriceChanged({price}) => {...state, price}
  | _ => state
  }

let decide = (_state, command) =>
  switch command {
  | SyncNewProduct({productId, name, price}) => Ok([CatalogProductSynced({productId, name, price})])
  | ChangeSyncedPrice({productId, price}) => Ok([CatalogProductPriceChanged({productId, price})])
  }
