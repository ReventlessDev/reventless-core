// ProductsExtensionPoint spec — stable public API from Catalog

let name = "Catalog.Products"
let moduleUrl: string = %raw(`import.meta.url`)

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
