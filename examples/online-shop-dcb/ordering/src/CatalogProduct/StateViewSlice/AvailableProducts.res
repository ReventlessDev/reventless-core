// AvailableProducts StateViewSlice.
// Projects synced catalog product events into a queryable "available products" read model.
@@reventless.spec

@schema
type state = {productId: string, name: string, price: float}

@schema
type consumedEvent =
  | CatalogProductSynced({productId: string, name: string, price: float})
  | CatalogProductPriceChanged({productId: string, price: float})
