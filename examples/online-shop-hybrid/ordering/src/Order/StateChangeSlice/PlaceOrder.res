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

// `OrderPlaced` carries `orderId` (not partial) so the decision model can
// discriminate placements across the multi-clause query. Without it,
// OrderPlaced events from sibling orders that share a `productId` tag would
// leak in and falsely set "this order exists".
@schema
type consumedEvent =
  | OrderPlaced({orderId: string})
  | CatalogProductSynced({productId: string})

// `customerId` is payload data, not a DCB consistency key: PlaceOrder reads
// no events filtered by customerId, so adding it to the DCB query produces
// false-positive ConditionalCheckFailed conflicts. The previous PlaceOrder's
// customerId fence position is newer than this slice's `after`, so a
// conditional `lastPosition <= :after` on the customerId fence rejects
// every subsequent placement by the same customer. `@noDcbTag` keeps customerId
// out of the query; the event still tags it (downstream consumers can index
// by customer), but the slice no longer fences on it.
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
