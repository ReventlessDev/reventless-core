// Orders StateViewSlice.
// Projects order events from the shared ordering event log into an Orders read model.
@@reventless.spec

@schema
type status =
  | Placed
  | Shipped
  | Cancelled

@schema
type state = {
  orderId: string,
  customerId: string,
  productIds: array<string>,
  @status status: status,
}

@schema
type consumedEvent =
  | OrderPlaced({orderId: string, customerId: string, productIds: array<string>})
  | OrderShipped({orderId: string})
  | OrderCancelled({orderId: string})
