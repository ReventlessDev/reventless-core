// Ordering's extension subscribing to Catalog's ProductsExtensionPoint.
// Routes ProductBecameAvailable / ProductPriceChanged events to CatalogProduct commands.

open ReventlessInfra.ExtensionMapping

module ExtensionPoint = CatalogSpec.ProductsExtensionPoint

module ProductMapping = {
  module ExtensionPoint = ExtensionPoint
  module Aggregate = CatalogProduct

  open Aggregate
  open ExtensionPoint
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ProductBecameAvailable({productId, name, price}) => [
        PublishAggregateCommand(productId, Sync({name, price})),
      ]
    | ProductPriceChanged({productId, price}) => [
        PublishAggregateCommand(productId, UpdatePrice({price: price})),
      ]
    }

  let mapOutgoingEvent = None
}
