// PlaceOrder StateChangeSlice.
// Handles the PlaceOrder command; rejects duplicate placement and validates
// that all referenced products have been synced to the ordering event log.

@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({orderId: OrderId.t})
  | CatalogProductSynced({productId: CatalogSpec.ProductId.t})

@schema
type command =
  | PlaceOrder({
      orderId: OrderId.t,
      customerId: CustomerId.t,
      @ref("AvailableProducts") productIds: array<CatalogSpec.ProductId.t>,
    })

@schema
type error =
  | OrderAlreadyPlaced
  | ProductsNotAvailable({missing: array<CatalogSpec.ProductId.t>})

@schema
type event =
  | OrderPlaced({
      orderId: OrderId.t,
      customerId: CustomerId.t,
      productIds: array<CatalogSpec.ProductId.t>,
    })
