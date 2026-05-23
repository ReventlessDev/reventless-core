// AvailableProducts StateViewSliceStream.
// Projects synced catalog product events into a queryable "available products" read model.
// Hidden from AutoUI: the user-facing product list lives in the Catalog plugin;
// this denormalised mirror exists purely as an Ordering-side lookup target.

@@reventless.spec
@@reventless.visibility(Internal)

@schema
type consumedEvent =
  | CatalogProductSynced({productId: string, name: string, price: float})
  | CatalogProductPriceChanged({productId: string, price: float})

@schema
type state = {productId: string, name: string, price: float}
