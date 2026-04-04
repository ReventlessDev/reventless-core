// SyncCatalogProduct StateChangeSlice.
// Maintains a local shadow of Catalog products inside the Ordering DCB event log.
@@reventless.spec

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
  | SyncNewProduct({productId: string, name: string, price: float})
  | ChangeSyncedPrice({productId: string, price: float})

@schema
type error = unit // always succeeds — sync is idempotent

@schema
type event =
  | CatalogProductSynced({
      productId: string,
      name: string,
      price: float,
    })
  | CatalogProductPriceChanged({
      productId: string,
      price: float,
    })

let decide = (_state, command) =>
  switch command {
  | SyncNewProduct({productId, name, price}) => Ok([CatalogProductSynced({productId, name, price})])
  | ChangeSyncedPrice({productId, price}) => Ok([CatalogProductPriceChanged({productId, price})])
  }
