// Maps internal Order events to the OrdersExtensionPoint public API, one published
// event per product in a batch.
@@reventless.spec

module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint
module Delegate = Order

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Order.Placed({customerId, productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(
        productId,
        OrderingSpec.Orders_ExtensionPoint.ItemOrdered({productId, orderId: _id, customerId}),
      )
    )
  | Order.Cancelled({productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(
        productId,
        OrderingSpec.Orders_ExtensionPoint.ItemOrderCancelled({productId, orderId: _id}),
      )
    )
  | _ => []
  }
)
