// Catalog's extension subscribing to Ordering's OrdersExtensionPoint.
// Routes ItemOrdered / ItemOrderCancelled events to ProductDemand commands.

open ReventlessInfra.ExtensionMapping

module Spec = OrdersExtensionPointSpec

module DemandMappingImpl = {
  module ExtensionPoint = Spec
  // Aggregate pattern: ProductDemand spec satisfies Aggregate.Spec directly — no adapter needed.
  module Aggregate = ProductDemand

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Spec.ItemOrdered({productId, orderId}) => [
        PublishAggregateCommand(
          productId,
          ProductDemand.RecordDemand({productId, orderId}),
        ),
      ]
    | Spec.ItemOrderCancelled({productId, orderId}) => [
        PublishAggregateCommand(
          productId,
          ProductDemand.RevokeDemand({productId, orderId}),
        ),
      ]
    }

  let mapOutgoingEvent = None
}

module DemandMappingT = Make(Spec, DemandMappingImpl)

module Mappings = {
  module Spec = Spec
  module type Mapping = T with module ExtensionPoint := Spec
  let name = "CatalogDemand"
  let mappings: array<module(Mapping)> = [module(DemandMappingT)]
}
