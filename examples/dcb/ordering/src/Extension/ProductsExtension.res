// Ordering's extension subscribing to Catalog's ProductsExtensionPoint.
// Routes ProductBecameAvailable / ProductPriceChanged events to SyncCatalogProduct commands.

open Reventless
open Reventless.ExtensionMapping

module Spec = ProductsExtensionPointSpec

module ProductMappingImpl = {
  module ExtensionPoint = Spec

  // DCB adapter: wraps SyncCatalogProduct as Aggregate.Spec so ExtensionMapping.Make
  // can encode commands routed to this StateChangeSlice.
  module Aggregate = {
    let name = SyncCatalogProduct.name
    module Id = Id.String
    type command = SyncCatalogProduct.command
    let commandSchema = SyncCatalogProduct.commandSchema
    @schema type event = unit // unused: mapOutgoingEvent = None
    @schema type error = unit
  }

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Spec.ProductBecameAvailable({productId, name, price}) => [
        PublishAggregateCommand(
          productId,
          SyncCatalogProduct.SyncNewProduct({productId, name, price}),
        ),
      ]
    | Spec.ProductPriceChanged({productId, price}) => [
        PublishAggregateCommand(
          productId,
          SyncCatalogProduct.UpdateSyncedPrice({productId, price}),
        ),
      ]
    }

  let mapOutgoingEvent = None
}

// Compile the Impl into a pre-encoded Mapping module.
module ProductMappingT = ReventlessCore.ExtensionMapping.Make(Spec, ProductMappingImpl)

module Mappings = {
  module Spec = Spec
  module type Mapping = ReventlessCore.ExtensionMapping.T with module ExtensionPoint := Spec
  let name = "OrderingProducts"
  let mappings: array<module(Mapping)> = [module(ProductMappingT)]
}
