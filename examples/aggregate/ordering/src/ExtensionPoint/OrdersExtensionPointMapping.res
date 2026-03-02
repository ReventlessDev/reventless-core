// Maps internal Order aggregate events to the stable OrdersExtensionPoint public API.
// Decomposes a batch OrderPlaced (multiple productIds) into one ItemOrdered per product.

open ReventlessInfra.ExtensionPointMapping

module ExtensionPoint = OrdersExtensionPointSpec

// Aggregate pattern: the Order spec IS the Aggregate module — no adapter required.
module Aggregate = Order

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Order.OrderPlaced({orderId, customerId, productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(
        productId,
        OrdersExtensionPointSpec.ItemOrdered({productId, orderId, customerId}),
      )
    )
  | Order.OrderCancelled({orderId, productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(
        productId,
        OrdersExtensionPointSpec.ItemOrderCancelled({productId, orderId}),
      )
    )
  | _ => []
  }
)
