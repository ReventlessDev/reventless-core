// Maps internal Ordering events to the stable OrdersExtensionPoint public API.
// Decomposes batch OrderPlaced / OrderCancelled events into per-product EP events.
@@reventless.spec

module ExtensionPoint = OrderingSpec.OrdersExtensionPoint

// DCB adapter: defines the event type used for outgoing event mapping.
// Only the events relevant to the extension point are included.
module Delegate = {
  let name = "OrderingEventLog"
  @schema
  type event =
    | OrderPlaced({orderId: string, customerId: string, productId: array<string>})
    | OrderCancelled({orderId: string, productId: array<string>})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.OrderPlaced({orderId, customerId, productId}) =>
    productId->Array.map(pid =>
      PublishEvent(
        pid,
        OrderingSpec.OrdersExtensionPoint.ItemOrdered({productId: pid, orderId, customerId}),
      )
    )
  | Delegate.OrderCancelled({orderId, productId}) =>
    productId->Array.map(pid =>
      PublishEvent(pid, OrderingSpec.OrdersExtensionPoint.ItemOrderCancelled({productId: pid, orderId}))
    )
  }
)
