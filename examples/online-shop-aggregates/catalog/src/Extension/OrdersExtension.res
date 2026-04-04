// Catalog's extension subscribing to Ordering's OrdersExtensionPoint.
// Routes ItemOrdered / ItemOrderCancelled events to ProductDemand commands.

open ReventlessInfra.ExtensionMapping

module DemandMapping = {
  module ExtensionPoint = OrderingSpec.OrdersExtensionPoint
  module Delegate = ProductDemand

  open ExtensionPoint
  open Delegate
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
