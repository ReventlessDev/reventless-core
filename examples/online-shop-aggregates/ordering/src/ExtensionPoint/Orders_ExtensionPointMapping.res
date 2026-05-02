// Maps internal Order aggregate events to the stable OrdersExtensionPoint public API.
// Decomposes a batch OrderPlaced (multiple productIds) into one ItemOrdered per product.
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
