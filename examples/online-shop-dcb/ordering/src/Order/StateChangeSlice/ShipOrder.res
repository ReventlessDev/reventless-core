// ShipOrder StateChangeSlice.
// Requires order to exist and not be cancelled; idempotent if already shipped.
@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced
  | OrderShipped
  | OrderCancelled

@schema
type command =
  | ShipOrder({orderId: string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyCancelled

@schema
type event = OrderShipped({orderId: string})

type lifecycleState = Orders.lifecycle

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | ShipOrder(_) => Moves([Orders.Placed], Orders.Shipped)
  }
}
