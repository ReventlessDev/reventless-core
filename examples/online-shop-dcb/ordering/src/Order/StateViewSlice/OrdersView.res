// OrdersView StateViewSlice.
// Projects order events from the shared ordering event log into an Orders read model.
@@reventless.spec

@schema
type state = {
  orderId: string,
  customerId: string,
  productIds: array<string>,
  status: string, // "placed" | "shipped" | "cancelled"
}

@schema
type consumedEvent =
  | OrderPlaced({orderId: string, customerId: string, productIds: array<string>})
  | OrderShipped({orderId: string})
  | OrderCancelled({orderId: string})
