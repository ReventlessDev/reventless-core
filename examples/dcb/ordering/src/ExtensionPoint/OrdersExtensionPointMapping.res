// Maps internal OrderingEventLog events to the stable OrdersExtensionPoint public API.
// Decomposes batch OrderPlaced / OrderCancelled events into per-product EP events.

open Reventless
open Reventless.ExtensionPointMapping

module ExtensionPoint = OrdersExtensionPointSpec

// DCB adapter: exposes OrderingEventLog as Aggregate.Spec so ExtensionPointMapping.Make
// can decode outgoing events. Only needed because mapOutgoingEvent is Some.
module Aggregate = {
  let name = "OrderingEventLog"
  module Id = Id.String
  @schema type command = unit
  @schema type event = OrderingEventLog.event
  @schema type error = unit
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | OrderingEventLog.OrderPlaced({orderId, customerId, productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(
        productId,
        OrdersExtensionPointSpec.ItemOrdered({productId, orderId, customerId}),
      )
    )
  | OrderingEventLog.OrderCancelled({orderId, productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(productId, OrdersExtensionPointSpec.ItemOrderCancelled({productId, orderId}))
    )
  | _ => []
  }
)
