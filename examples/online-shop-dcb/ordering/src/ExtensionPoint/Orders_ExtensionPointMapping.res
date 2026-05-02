// Maps internal Ordering events to the stable Orders_ExtensionPoint public API.
// Decomposes batch OrderPlaced / OrderCancelled events into per-product EP events.
@@reventless.spec

module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint

// DCB adapter: defines the event type used for outgoing event mapping.
// Only the events relevant to the extension point are included.
module Delegate = {
  let name = "OrderingEventLog"
  @schema
  type event =
    | OrderPlaced({orderId: string, customerId: string, productIds: array<string>})
    | OrderCancelled({orderId: string, productIds: array<string>})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.OrderPlaced({orderId, customerId, productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(
        productId,
        OrderingSpec.Orders_ExtensionPoint.ItemOrdered({productId, orderId, customerId}),
      )
    )
  | Delegate.OrderCancelled({orderId, productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(productId, OrderingSpec.Orders_ExtensionPoint.ItemOrderCancelled({productId, orderId}))
    )
  }
)
