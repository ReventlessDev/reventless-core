// Catalog's extension subscribing to Ordering's Orders_ExtensionPoint.
// Routes ItemOrdered / ItemOrderCancelled events to RecordProductDemand commands.

@@reventless.extension

module Mapping = {
  module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint
  module Delegate = RecordProductDemand

  open ExtensionPoint
  open RecordProductDemand
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        PublishAggregateCommand(productId, RecordDemand({productId, orderId})),
      ]
    | ItemOrderCancelled({productId, orderId}) => [
        PublishAggregateCommand(productId, RevokeDemand({productId, orderId})),
      ]
    }

  let mapOutgoingEvent = None
}
