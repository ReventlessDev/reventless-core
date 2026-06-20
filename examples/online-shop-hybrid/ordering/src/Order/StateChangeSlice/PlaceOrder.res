// PlaceOrder StateChangeSlice.
// Handles the PlaceOrder command; rejects duplicate placement and validates
// that all referenced products have been synced to the ordering event log.
//
// The tagged array `productIds: array<string>` triggers automatic multi-clause
// query construction: one OR clause per orderId and per productId element —
// fetching both Order and CatalogProduct events. The plural field name is
// auto-singularised by the PPX so each element is stored under tag key
// `productId`, sharing the key with single-value `productId: string` producers.

@@reventless.spec

// `OrderPlaced` carries `orderId` so `evolve` can record THIS order's existence
// (the `orderId` clause reads the order's own partition). `CatalogProductSynced`
// is read by `productId` to confirm availability — a monotonic existence check,
// not optimistic concurrency: the adapter fences `productId` only via
// productId-partitioned events (CatalogProductSynced), so two orders of the same
// product never conflict. See
// `docs/analysis/dcb-fence-scope-vs-read-scope-mismatch.md`.
@schema
type consumedEvent =
  | OrderPlaced({orderId: string})
  | CatalogProductSynced({productId: string})

// `customerId` is payload data, not a DCB consistency key. `@noDcbTag` keeps it
// out of the query so PlaceOrder is not coupled to the customer event stream
// (otherwise a concurrent customer change would conflict an unrelated order).
// The event still tags `customerId` so downstream consumers can index by
// customer; as a secondary (non-partition) tag it is never fenced.
@schema
type command =
  PlaceOrder({
    @partitionTag orderId: string,
    @noDcbTag customerId: string,
    productIds: array<string>,
  })

@schema
type error =
  | OrderAlreadyPlaced
  | ProductsNotAvailable({missing: array<string>})

@schema
type event =
  OrderPlaced({@partitionTag orderId: string, customerId: string, productIds: array<string>})
