// SyncCatalogProduct StateChangeSlice.
// Maintains a local shadow of Catalog products inside the Ordering DCB event log.

@@reventless.spec

@schema
type consumedEvent =
  | CatalogProductSynced({name: string, price: float})
  | CatalogProductPriceChanged({price: float})

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
