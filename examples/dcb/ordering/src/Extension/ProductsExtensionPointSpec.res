// Local copy of Catalog's ProductsExtensionPoint spec.
// Must stay in sync with catalog/src/ExtensionPoint/ProductsExtensionPointSpec.res.
// The runtime matches extension points by name, so `name` must be identical.

let name = "Catalog.Products"

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
