// Catalog's extension subscribing to Ordering's OrdersExtensionPoint.
// Routes ItemOrdered / ItemOrderCancelled events to ProductDemand commands.

open ReventlessInfra.ExtensionMapping

module ExtensionPoint = OrderingSpec.OrdersExtensionPoint

module DemandMapping = {
  module ExtensionPoint = ExtensionPoint
  module Aggregate = ProductDemand

  open Aggregate
  open ExtensionPoint
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        PublishAggregateCommand(productId, Record({orderId: orderId})),
      ]
    | ItemOrderCancelled({productId, orderId}) => [
        PublishAggregateCommand(productId, Revoke({orderId: orderId})),
      ]
    }

  let mapOutgoingEvent = None
}
