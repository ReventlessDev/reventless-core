// SyncCatalogProduct StateChangeSlice.
// Maintains a local shadow of Catalog products inside the Ordering DCB event log.

@@reventless.spec

@schema
type consumedEvent =
  | CatalogProductSynced({name: string, price: Reventless.Money.t})
  | CatalogProductPriceChanged({price: Reventless.Money.t})

@schema
type command =
  | SyncNewProduct({productId: string, name: string, price: Reventless.Money.t})
  | ChangeSyncedPrice({productId: string, price: Reventless.Money.t})

@schema
type error = unit // always succeeds — sync is idempotent

@schema
type event =
  | CatalogProductSynced({
      productId: string,
      name: string,
      price: Reventless.Money.t,
    })
  | CatalogProductPriceChanged({
      productId: string,
      price: Reventless.Money.t,
    })
