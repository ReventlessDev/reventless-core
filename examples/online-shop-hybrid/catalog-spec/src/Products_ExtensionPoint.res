// Products_ExtensionPoint spec — stable public API from Catalog to Ordering.
// Extensions subscribing to this EP receive product availability events.

@@reventless.spec

@schema
type command = unit // read-only: no inbound commands

// Prices cross this boundary as `Money.t` rather than as a bare number. A
// subscriber receiving `1000` would have to be told, out of band, which currency
// and which minor unit that is — and a public API is exactly where an out-of-band
// convention goes wrong, because the two sides ship separately.
//
// **One withdrawal, not two.** Catalog's lifecycle distinguishes `Archived` from
// `Discontinued`; a subscriber needs "orderable or not" and has no use for the
// difference. An extension point that mirrored the lifecycle would make every
// future state of it a change to a published contract, which is the opposite of
// what the boundary is for.
//
// **`ProductWithdrawn` and `ProductRelisted` carry only the id, and that is the
// design.** The relist is the case that proves it: `ProductBecameAvailable`
// carries `name` and `price` because Ordering had nothing when it arrived, but on
// a relist Ordering already holds both in its own shadow — `SyncCatalogProduct`
// exists to maintain exactly that — and the shadow survives the read model's
// delete. Re-publishing `ProductBecameAvailable` instead would force the mapping
// to source `name` and `price` from a `ProductUnarchived` that has no reason to
// carry them, so Catalog would end up enriching an event to serve a subscriber's
// bookkeeping.
//
// **Adding an event here is a breaking change for an independently deployed
// subscriber**: one compiled against the old spec receives a variant its
// `mapIncomingEvent` cannot decode. This example gets away with it because
// `catalog` and `ordering` deploy together. The next extension point to grow an
// event may not.
@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: Reventless.Money.t})
  | ProductPriceChanged({productId: string, price: Reventless.Money.t})
  | ProductWithdrawn({productId: string})
  | ProductRelisted({productId: string})

// Non-domain side effects an EP-side mapping can fire alongside its events.
// Fired from the publishing side; not durable, not replayable, not routed to
// subscribers. See `catalog/src/ExtensionPoint/Products_ExtensionPointMapping.res`.
@schema
type directive =
  | EmitPricingUpdate({productId: string, price: Reventless.Money.t})
