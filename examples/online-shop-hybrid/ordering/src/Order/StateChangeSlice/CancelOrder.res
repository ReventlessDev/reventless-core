// CancelOrder StateChangeSlice.
// Requires order to exist and not be shipped; idempotent if already cancelled.

@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({productIds: array<string>})
  | OrderShipped
  | OrderCancelled
  | OrderReopened

@schema
type command =
  | @transition(([Orders.Placed]) => Orders.Cancelled) CancelOrder({orderId: string})
  // Internal: admin/automation only. The way back out of `Cancelled`, and a real
  // edge of the lifecycle — being unreachable from the API does not make it less
  // of one, and leaving it undeclared is what let the reopened order go nowhere.
  | @noApi @transition(([Orders.Cancelled]) => Orders.Placed) ReopenOrder({orderId: string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyShipped

@schema
type event =
  | OrderCancelled({
      orderId: string,
      productIds: array<string>,
    })
  | OrderReopened({orderId: string})
