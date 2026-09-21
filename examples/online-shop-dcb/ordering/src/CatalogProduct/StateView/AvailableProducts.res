// AvailableProducts StateViewSlice.
// Projects synced catalog product events into a queryable "available products" read model.
// This view exists to support Order placement and isn't shown in AutoUI panels.
@@reventless.spec
@@reventless.visibility(Internal)

// Rows are keyed by this identity.
module Key = CatalogSpec.ProductId

@schema
type state = {productId: CatalogSpec.ProductId.t, name: string, price: float}

@schema
type consumedEvent =
  | CatalogProductSynced({productId: CatalogSpec.ProductId.t, name: string, price: float})
  | CatalogProductPriceChanged({productId: CatalogSpec.ProductId.t, price: float})
