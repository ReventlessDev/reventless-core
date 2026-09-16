// PlaceOrder StateChangeSlice.
// Handles the PlaceOrder command; rejects duplicate placement and validates
// that all referenced products have been synced to the ordering event log.

@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({orderId: string})
  | CatalogProductSynced({productId: string})

@schema
type command =
  | PlaceOrder({
      orderId: string,
      customerId: string,
      @ref("AvailableProducts") productIds: array<string>,
    })

@schema
type error =
  | OrderAlreadyPlaced
  | ProductsNotAvailable({missing: array<string>})

@schema
type event = OrderPlaced({orderId: string, customerId: string, productIds: array<string>})
