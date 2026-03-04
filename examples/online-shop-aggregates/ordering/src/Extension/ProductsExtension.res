// Ordering's extension subscribing to Catalog's ProductsExtensionPoint.
// Routes ProductBecameAvailable / ProductPriceChanged events to CatalogProduct commands.

open ReventlessInfra.ExtensionMapping

module ProductMapping = {
  module Source = CatalogSpec.ProductsExtensionPoint
  module Target = CatalogProduct

  module ExtensionPoint = Source
  module Aggregate = Target

  open Source
  open Target
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
