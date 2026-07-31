// Products_ExtensionPoint spec — stable public API from Catalog to Ordering.
// Extensions subscribing to this EP receive product availability events.

@@reventless.spec

@schema
type command = unit // read-only: no inbound commands

// Prices cross this boundary as `Money.t` rather than as a bare number. A
// subscriber receiving `1000` would have to be told, out of band, which currency
// and which minor unit that is — and a public API is exactly where an out-of-band
// convention goes wrong, because the two sides ship separately.
@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: Reventless.Money.t})
  | ProductPriceChanged({productId: string, price: Reventless.Money.t})

// Non-domain side effects an EP-side mapping can fire alongside its events.
// Fired from the publishing side; not durable, not replayable, not routed to
// subscribers. See `catalog/src/ExtensionPoint/Products_ExtensionPointMapping.res`.
@schema
type directive =
  | EmitPricingUpdate({productId: string, price: Reventless.Money.t})
