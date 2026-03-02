// Catalog's extension subscribing to Ordering's OrdersExtensionPoint.
// Routes ItemOrdered / ItemOrderCancelled events to RecordProductDemand commands.

open Reventless
open ReventlessInfra.ExtensionMapping

module Spec = OrdersExtensionPointSpec

module DemandMappingImpl = {
  module ExtensionPoint = Spec

  // DCB adapter: wraps RecordProductDemand as Aggregate.Spec so ExtensionMapping.Make
  // can encode commands routed to this StateChangeSlice.
  module Aggregate = {
    let name = RecordProductDemand.name
    module Id = Id.String
    type command = RecordProductDemand.command
    let commandSchema = RecordProductDemand.commandSchema
    @schema type event = unit // unused: mapOutgoingEvent = None
    @schema type error = unit
  }

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Spec.ItemOrdered({productId, orderId}) => [
        PublishAggregateCommand(
          productId,
          RecordProductDemand.RecordDemand({productId, orderId}),
        ),
      ]
    | Spec.ItemOrderCancelled({productId, orderId}) => [
        PublishAggregateCommand(
          productId,
          RecordProductDemand.RevokeDemand({productId, orderId}),
        ),
      ]
    }

  let mapOutgoingEvent = None
}

// Compile the Impl into a pre-encoded Mapping module.
module DemandMappingT = Make(Spec, DemandMappingImpl)

module Mappings = {
  module Spec = Spec
  module type Mapping = T with module ExtensionPoint := Spec
  let name = "CatalogDemand"
  let mappings: array<module(Mapping)> = [module(DemandMappingT)]
}
