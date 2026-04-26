// CancelOrder StateChangeSlice.
// Requires order to exist and not be shipped; idempotent if already cancelled.
@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({productIds: array<string>})
  | OrderShipped
  | OrderCancelled

@schema
type command = CancelOrder({orderId: string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyShipped

@schema
type event = OrderCancelled({
  @partitionTag orderId: string,
  productIds: array<string>,
})
