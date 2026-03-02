// Ordering's extension subscribing to Catalog's ProductsExtensionPoint.
// Routes ProductBecameAvailable / ProductPriceChanged events to CatalogProduct commands.

open Reventless.ExtensionMapping

module Spec = ProductsExtensionPointSpec

module ProductMappingImpl = {
  module ExtensionPoint = Spec
  // Aggregate pattern: CatalogProduct spec satisfies Aggregate.Spec directly — no adapter needed.
  module Aggregate = CatalogProduct

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Spec.ProductBecameAvailable({productId, name, price}) => [
        PublishAggregateCommand(
          productId,
          CatalogProduct.SyncNewProduct({productId, name, price}),
        ),
      ]
    | Spec.ProductPriceChanged({productId, price}) => [
        PublishAggregateCommand(
          productId,
          CatalogProduct.UpdateSyncedPrice({productId, price}),
        ),
      ]
    }

  let mapOutgoingEvent = None
}

module ProductMappingT = Make(Spec, ProductMappingImpl)

module Mappings = {
  module Spec = Spec
  module type Mapping = T with module ExtensionPoint := Spec
  let name = "OrderingProducts"
  let mappings: array<module(Mapping)> = [module(ProductMappingT)]
}
