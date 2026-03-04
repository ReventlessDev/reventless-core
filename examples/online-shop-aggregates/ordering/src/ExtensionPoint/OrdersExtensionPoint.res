// Maps internal Order aggregate events to the stable OrdersExtensionPoint public API.
// Decomposes a batch OrderPlaced (multiple productIds) into one ItemOrdered per product.

open ReventlessInfra.ExtensionPointMapping

module ExtensionPoint = OrderingSpec.OrdersExtensionPoint

module OrderMapping = {
  module Aggregate = Order

  let mapIncomingCommand = (_id, _command, _meta) => []

  open Aggregate
  open ExtensionPoint
  let mapOutgoingEvent = Some((id, event, _meta, _queryEngine) =>
    switch event {
    | Placed({customerId, productIds}) =>
      productIds->Array.map(productId =>
        PublishEvent(
          productId,
          ItemOrdered({productId, orderId: id, customerId}),
        )
      )
    | Cancelled({productIds}) =>
      productIds->Array.map(productId =>
        PublishEvent(
          productId,
          ItemOrderCancelled({productId, orderId: id}),
        )
      )
    | _ => []
    }
  )
}
