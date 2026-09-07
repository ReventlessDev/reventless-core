// ShipOrder StateChangeSlice.
// Requires order to exist and not be cancelled; idempotent if already shipped.
//
// `OrderPlaced` carries a payload so it survives the DCB payload-less filter and
// lands in `consumedEventTypes`, overlapping the Orders view's consumed events.
// That is what links this slice to Orders (`consistencyRead=Orders`) so AutoUI's
// board offers it — shipping is a manual operator action on the Orders board, not
// automation-only. `commandTransition` below declares the whole edge outright —
// the states the command is legal in and the one it lands in — so the board
// resolves the drop from the declaration rather than guessing it from the
// command's name.
//
// `OrderShipped` names its customer for the same reason `OrderPlaced` does: an
// automation can only react to an occurrence that says whom it concerns. The
// value is folded across from `OrderPlaced` rather than decided here — this
// slice never reads it — so the shipment fact carries a recipient without the
// log ever holding an address.

@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({productIds: array<string>, customerId: string})
  | OrderShipped
  | OrderCancelled
  // The slice refuses on a cancellation, so it has to hear when one is undone.
  // Consuming `OrderCancelled` without its counterpart is how a slice comes to
  // decide on a fact that stopped being true.
  | OrderReopened

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Fulfilment"])) ShipOrder({orderId: string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyCancelled

@schema
type event =
  | OrderShipped({@partitionTag orderId: string, customerId: string})

type lifecycleState = Orders.lifecycle

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | ShipOrder(_) => Moves([Orders.Placed], Orders.Shipped)
  }
}
