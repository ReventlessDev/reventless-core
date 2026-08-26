// Catalog's extension subscribing to Ordering's Orders_ExtensionPoint.
// Routes ItemOrdered / ItemOrderCancelled events to RecordProductDemand commands.

@@reventless.extension

module Mapping = {
  module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint
  module Delegate = RecordProductDemand

  open ExtensionPoint
  open RecordProductDemand

  // Fire-and-forget side effect; query-based decisions belong in `mapIncomingEvent`.
  let directiveHandler = async (directive: ExtensionPoint.directive) =>
    switch directive {
    | EmitOrderRecordedTelemetry({productId, orderId}) =>
      Console.log(
        `[Catalog.OrdersExtension] telemetry: order recorded product=${productId} order=${orderId}`,
      )
    | EmitOrderCancelledTelemetry({productId, orderId}) =>
      Console.log(
        `[Catalog.OrdersExtension] telemetry: order cancelled product=${productId} order=${orderId}`,
      )
    }

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        PublishStateChangeSliceCommand(RecordDemand({productId, orderId})),
        HandleDirective(
          directiveHandler,
          EmitOrderRecordedTelemetry({productId, orderId}),
        ),
      ]
    | ItemOrderCancelled({productId, orderId}) => [
        PublishStateChangeSliceCommand(RevokeDemand({productId, orderId})),
        HandleDirective(
          directiveHandler,
          EmitOrderCancelledTelemetry({productId, orderId}),
        ),
      ]
    }

  let mapOutgoingEvent = None
}
