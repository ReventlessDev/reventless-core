// SyncCatalogProduct StateChangeSlice.
// Maintains a local shadow of Catalog products inside the Ordering DCB event log.

open Reventless

let name = "SyncCatalogProduct"
module Id = Reventless.Id.String
let moduleUrl: string = %raw(`import.meta.url`)

type state = {name: string, price: float}
let initialState = {name: "", price: 0.0}

@schema
type consumedEvent =
  | CatalogProductSynced({name: string, price: float})
  | CatalogProductPriceChanged({price: float})

let evolve = (state, event) =>
  switch event {
  | CatalogProductSynced({name, price}) => {name, price}
  | CatalogProductPriceChanged({price}) => {...state, price}
  }

@schema
type command =
  | SyncNewProduct({productId: @s.matches(DcbTag.string) string, name: string, price: float})
  | ChangeSyncedPrice({productId: @s.matches(DcbTag.string) string, price: float})

@schema
type error = unit // always succeeds — sync is idempotent

@schema
type event =
  | CatalogProductSynced({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      price: float,
    })
  | CatalogProductPriceChanged({
      productId: @s.matches(DcbTag.string) string,
      price: float,
    })

let decide = (_state, command) =>
  switch command {
  | SyncNewProduct({productId, name, price}) => Ok([CatalogProductSynced({productId, name, price})])
  | ChangeSyncedPrice({productId, price}) => Ok([CatalogProductPriceChanged({productId, price})])
  }
