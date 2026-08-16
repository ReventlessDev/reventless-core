// SyncCatalogProduct StateChangeSlice.
// Maintains a local shadow of Catalog products inside the Ordering DCB event log.

@@reventless.spec

@schema
type consumedEvent =
  | CatalogProductSynced({name: string, price: Reventless.Money.t})
  | CatalogProductPriceChanged({price: Reventless.Money.t})
  | CatalogProductWithdrawn
  | CatalogProductRelisted

@schema
type command =
  | SyncNewProduct({productId: string, name: string, price: Reventless.Money.t})
  | ChangeSyncedPrice({productId: string, price: Reventless.Money.t})
  // The withdrawal and the way back. Both carry only the id: the shadow this
  // slice maintains already holds the name and price, and it survives the read
  // model's delete — which is what lets a relist restore availability from state
  // Ordering owns rather than asking Catalog to re-send facts it already has.
  | WithdrawSyncedProduct({productId: string})
  | RelistSyncedProduct({productId: string})

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
  | CatalogProductWithdrawn({productId: string})
  // Carries the shadow's name and price so the projection can restore the row
  // without a second read: the fold has them in hand at exactly the moment the
  // decision is made, and an event that states what it caused is what makes the
  // projection a pure mapping.
  | CatalogProductRelisted({
      productId: string,
      name: string,
      price: Reventless.Money.t,
    })
