// Orders StateViewSlice.
// Projects order events from the shared ordering event log into an Orders read model.
@@reventless.spec

// Rows are keyed by this identity.
module Key = OrderId

@schema
type lifecycle =
  | Placed
  | Shipped
  | Cancelled

@schema
type state = {
  orderId: OrderId.t,
  customerId: CustomerId.t,
  productIds: array<CatalogSpec.ProductId.t>,
  // No annotation: the field name is the declaration. `@lifecycle` exists for
  // records whose lifecycle field is honestly called something else.
  lifecycle: lifecycle,
}

@schema
type consumedEvent =
  | OrderPlaced({
      orderId: OrderId.t,
      customerId: CustomerId.t,
      productIds: array<CatalogSpec.ProductId.t>,
    })
  | OrderShipped({orderId: OrderId.t})
  | OrderCancelled({orderId: OrderId.t})
