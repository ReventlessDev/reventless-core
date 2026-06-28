// PlaceOrder StateChangeSlice.
// Rejects duplicate placement and validates that all referenced products are
// available (synced to the ordering event log).

@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({orderId: string})
  | CatalogProductSynced({productId: string})

@schema
type command =
  PlaceOrder({
    @partitionTag orderId: string,
    // customerId is payload, not a query key — @noDcbTag stops it auto-tagging.
    @noDcbTag customerId: string,
    @ref("AvailableProducts") productIds: array<string>,
  })

@schema
type error =
  | OrderAlreadyPlaced
  | ProductsNotAvailable({missing: array<string>})

@schema
type event =
  OrderPlaced({@partitionTag orderId: string, customerId: string, productIds: array<string>})
