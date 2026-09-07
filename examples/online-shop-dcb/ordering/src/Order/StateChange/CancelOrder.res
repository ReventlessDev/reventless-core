// CancelOrder StateChangeSlice.
// Requires order to exist and not be shipped; idempotent if already cancelled.
@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({productIds: array<string>})
  | OrderShipped
  | OrderCancelled

@schema
type command =
  | CancelOrder({orderId: string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyShipped

@schema
type event = OrderCancelled({
  // orderId and productIds both tag — @partitionTag picks the storage partition.
  @partitionTag orderId: string,
  productIds: array<string>,
})

type lifecycleState = Orders.lifecycle

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | CancelOrder(_) => Moves([Orders.Placed], Orders.Cancelled)
  }
}
