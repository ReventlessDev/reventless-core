// Local copy of Catalog's ProductsExtensionPoint spec.
// Must match name = "Catalog.Products" exactly.

let name = "Catalog.Products"

@schema
type command = unit

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
