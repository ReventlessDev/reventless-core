// Catalog's extension subscribing to Ordering's OrdersExtensionPoint.
// Routes ItemOrdered / ItemOrderCancelled events to RecordProductDemand commands.

open Reventless
open ReventlessInfra.ExtensionMapping

module DemandMapping = {
  module Source = OrderingSpec.OrdersExtensionPoint
  module Target = RecordProductDemand

  // DCB adapter: wraps RecordProductDemand as Aggregate.Spec so ExtensionMapping.Make
  // can encode commands routed to this StateChangeSlice.
  module Aggregate = {
    let name = Target.name
    module Id = Id.String
    type command = Target.command
    let commandSchema = Target.commandSchema
    @schema type event = unit // unused: mapOutgoingEvent = None
    @schema type error = unit
    let moduleUrl: string = %raw(`import.meta.url`)
  }

  open Source
  open Target
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
