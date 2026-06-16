// Catalog's extension subscribing to Ordering's Orders_ExtensionPoint.
// Routes ItemOrdered / ItemOrderCancelled events to RecordProductDemand commands.

@@reventless.extension

module Mapping = {
  module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint
  module Delegate = RecordProductDemand

  open ExtensionPoint
  open RecordProductDemand

  // Extension-side directive handler: pure fire-and-forget
  // (`'directive => promise<unit>`). Query-based decisions live in
  // `mapIncomingEvent` (which has `_queryEngine`); the handler executes the
  // resulting side effect.
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
