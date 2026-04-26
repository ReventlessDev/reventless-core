// CancelOrder StateChangeSlice.
// Requires order to exist and not be shipped; idempotent if already cancelled.

@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({productId: array<string>})
  | OrderShipped
  | OrderCancelled
  | OrderReopened

@schema
type command =
  | CancelOrder({orderId: string})
  | @noApi ReopenOrder({orderId: string})  // Internal: admin/automation only

@schema
type error =
  | OrderNotFound
  | OrderAlreadyShipped

@schema
type event =
  | OrderCancelled({
      orderId: string,
      productId: array<string>,
    })
  | OrderReopened({orderId: string})
