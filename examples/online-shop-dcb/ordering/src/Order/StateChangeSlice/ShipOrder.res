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
  | @transition(([Orders.Placed]) => Orders.Shipped) ShipOrder({orderId: string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyCancelled

@schema
type event = OrderShipped({orderId: string})
