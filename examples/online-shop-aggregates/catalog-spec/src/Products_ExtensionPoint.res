// Products_ExtensionPoint spec — stable public API from Catalog to Ordering.
// Extensions subscribing to this EP receive product availability events.

@@reventless.spec

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: ProductId.t, name: string, price: float})
  | ProductPriceChanged({productId: ProductId.t, price: float})

@schema
type directive = unit
