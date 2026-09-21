// CancelOrder StateChangeSlice.
// Requires order to exist and not be shipped; idempotent if already cancelled.

@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({productIds: array<CatalogSpec.ProductId.t>})
  | OrderShipped
  | OrderCancelled
  | OrderReopened

@schema
type command =
  | CancelOrder({orderId: OrderId.t})
  // Internal: admin/automation only.
  | @noApi ReopenOrder({orderId: OrderId.t})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyShipped

@schema
type event =
  | OrderCancelled({orderId: OrderId.t, productIds: array<CatalogSpec.ProductId.t>})
  | OrderReopened({orderId: OrderId.t})

// `ReopenOrder` is the way back out of `Cancelled`, and a real edge of the
// lifecycle — being unreachable from the API does not make it less of one, and
// leaving it undeclared is what let the reopened order go nowhere.
type lifecycleState = Orders.lifecycle

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | CancelOrder(_) => Moves([Orders.Placed], Orders.Cancelled)
  | ReopenOrder(_) => Moves([Orders.Cancelled], Orders.Placed)
  }
}
