// ShipOrder StateChangeSlice.
// Requires order to exist and not be cancelled; idempotent if already shipped.
//
// `OrderPlaced` carries a payload so it survives the DCB payload-less filter and
// lands in `consumedEventTypes`, overlapping the Orders view's consumed events.
// That is what links this slice to Orders (`consistencyRead=Orders`) so AutoUI's
// board offers it — shipping is a manual operator action on the Orders board, not
// automation-only. `@targetState("Shipped")` declares the transition outright, so
// the board resolves the drop via its DeclaredTarget tier rather than guessing.

@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({productIds: array<string>})
  | OrderShipped
  | OrderCancelled

@schema
type command =
  | @allowedStates([Orders.Placed])
  @targetState(Orders.Shipped)
  @authorize(AllowGroups(["Admin", "Fulfilment"])) ShipOrder({orderId: string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyCancelled

@schema
type event =
  | OrderShipped({orderId: string})
