// Catalog's extension subscribing to Ordering's Orders_ExtensionPoint.
// Routes ItemOrdered / ItemOrderCancelled events to RecordProductDemand commands.

@@reventless.extension

module Mapping = {
  module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint
  module Delegate = RecordProductDemand

  open ExtensionPoint
  open RecordProductDemand

  // Fire-and-forget side effect; query-based decisions belong in `mapIncomingEvent`. Logging
  // only here, under this extension's component; a real one might post telemetry.
  let directiveHandler = async (directive: ExtensionPoint.directive) => {
    let comp = "Extension(Ordering.Orders.Catalog)"
    switch directive {
    | EmitOrderRecordedTelemetry({productId, orderId}) =>
      ReventlessInfra.AppLog.info(
        ~comp,
        `telemetry: order recorded product=${productId} order=${orderId}`,
      )
    | EmitOrderCancelledTelemetry({productId, orderId}) =>
      ReventlessInfra.AppLog.info(
        ~comp,
        `telemetry: order cancelled product=${productId} order=${orderId}`,
      )
    }
  }

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    // Ordering's contract carries a plain string; the catalog decides by its own
    // ProductId.
    switch event {
    | ItemOrdered({productId, orderId}) => [
        PublishStateChangeSliceCommand(
          RecordDemand({productId: CatalogSpec.ProductId.makeFromString(productId), orderId}),
        ),
        HandleDirective(directiveHandler, EmitOrderRecordedTelemetry({productId, orderId})),
      ]
    | ItemOrderCancelled({productId, orderId}) => [
        PublishStateChangeSliceCommand(
          RevokeDemand({productId: CatalogSpec.ProductId.makeFromString(productId), orderId}),
        ),
        HandleDirective(directiveHandler, EmitOrderCancelledTelemetry({productId, orderId})),
      ]
    }

  let mapOutgoingEvent = None
}
