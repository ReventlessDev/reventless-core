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
    // Ordering's contract carries a plain string; the catalog decides by its own
    // ProductId.
    | ItemOrdered({productId, orderId}) => [
        PublishStateChangeSliceCommand(
          RecordDemand({productId: CatalogSpec.ProductId.makeFromString(productId), orderId}),
        ),
      ]
    | ItemOrderCancelled({productId, orderId}) => [
        PublishStateChangeSliceCommand(
          RevokeDemand({productId: CatalogSpec.ProductId.makeFromString(productId), orderId}),
        ),
      ]
    }

  let mapOutgoingEvent = None
}
