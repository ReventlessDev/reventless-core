// AvailableProducts StateViewSlice.
// Projects synced catalog product events into a queryable "available products" read model.
// This view exists to support Order placement and isn't shown in AutoUI panels.
@@reventless.spec
@@reventless.visibility(Internal)

@schema
type state = {productId: string, name: string, price: float}

@schema
type consumedEvent =
  | CatalogProductSynced({productId: string, name: string, price: float})
  | CatalogProductPriceChanged({productId: string, price: float})
