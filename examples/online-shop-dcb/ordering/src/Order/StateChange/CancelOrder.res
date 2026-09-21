// CancelOrder StateChangeSlice.
// Requires order to exist and not be shipped; idempotent if already cancelled.
@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({productIds: array<CatalogSpec.ProductId.t>})
  | OrderShipped
  | OrderCancelled

@schema
type command = CancelOrder({orderId: OrderId.t})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyShipped

@schema
type event = OrderCancelled({orderId: OrderId.t, productIds: array<CatalogSpec.ProductId.t>})

type lifecycleState = Orders.lifecycle

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | CancelOrder(_) => Moves([Orders.Placed], Orders.Cancelled)
  }
}
