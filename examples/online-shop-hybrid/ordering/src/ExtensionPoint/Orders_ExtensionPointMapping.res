// Maps internal Ordering events to the Orders_ExtensionPoint public API, one
// published event per product in a batch.
@@reventless.spec

module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint

// DCB adapter carrying only the events this port maps.
module Delegate = {
  let name = "OrderingDcbEventLog"
  @schema
  type event =
    | OrderPlaced({orderId: string, customerId: string, productIds: array<string>})
    | OrderCancelled({orderId: string, productIds: array<string>})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.OrderPlaced({orderId, customerId, productIds}) =>
    productIds->Array.map(pid =>
      PublishEvent(
        pid,
        OrderingSpec.Orders_ExtensionPoint.ItemOrdered({productId: pid, orderId, customerId}),
      )
    )
  | Delegate.OrderCancelled({orderId, productIds}) =>
    productIds->Array.map(pid =>
      PublishEvent(pid, OrderingSpec.Orders_ExtensionPoint.ItemOrderCancelled({productId: pid, orderId}))
    )
  }
)
