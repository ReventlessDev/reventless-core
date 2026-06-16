// Products_ExtensionPoint spec — stable public API from Catalog to Ordering.
// Extensions subscribing to this EP receive product availability events.

@@reventless.spec

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

// Non-domain side effects an EP-side mapping can fire alongside its events.
// Fired from the publishing side; not durable, not replayable, not routed to
// subscribers. See `catalog/src/ExtensionPoint/Products_ExtensionPointMapping.res`.
@schema
type directive =
  | EmitPricingUpdate({productId: string, price: float})
