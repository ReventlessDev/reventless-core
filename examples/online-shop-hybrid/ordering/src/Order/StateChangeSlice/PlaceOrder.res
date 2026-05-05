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

@schema
type command =
  PlaceOrder({@partitionTag orderId: string, customerId: string, productIds: array<string>})

@schema
type error =
  | OrderAlreadyPlaced
  | ProductsNotAvailable({missing: array<string>})

@schema
type event =
  OrderPlaced({@partitionTag orderId: string, customerId: string, productIds: array<string>})
