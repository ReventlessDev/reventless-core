// PlaceOrder StateChangeSlice.
// Handles the PlaceOrder command; rejects duplicate placement and validates
// that all referenced products have been synced to the ordering event log.
//
// The tagged array `productId: array<string>` triggers automatic multi-clause
// query construction: one OR clause per orderId and per productId element —
// fetching both Order and CatalogProduct events.

@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced
  | CatalogProductSynced({productId: string})

@schema
type command =
  PlaceOrder({@partitionTag orderId: string, customerId: string, productId: array<string>})

@schema
type error =
  | OrderAlreadyPlaced
  | ProductsNotAvailable({missing: array<string>})

@schema
type event =
  OrderPlaced({@partitionTag orderId: string, customerId: string, productId: array<string>})
