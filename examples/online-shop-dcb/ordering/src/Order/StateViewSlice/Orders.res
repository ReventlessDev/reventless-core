// Orders StateViewSlice.
// Projects order events from the shared ordering event log into an Orders read model.
@@reventless.spec

@schema
type lifecycle =
  | Placed
  | Shipped
  | Cancelled

@schema
type state = {
  orderId: string,
  customerId: string,
  productIds: array<string>,
  // No annotation: the field name is the declaration. `@lifecycle` exists for
  // records whose lifecycle field is honestly called something else.
  lifecycle: lifecycle,
}

@schema
type consumedEvent =
  | OrderPlaced({orderId: string, customerId: string, productIds: array<string>})
  | OrderShipped({orderId: string})
  | OrderCancelled({orderId: string})
