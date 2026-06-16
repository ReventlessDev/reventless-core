// Products_ExtensionPoint spec — stable public API from Catalog to Ordering.
// Extensions subscribing to this EP receive product availability events.

@@reventless.spec

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
