// Ordering's extension subscribing to Catalog's ProductsExtensionPoint.
// Routes ProductBecameAvailable / ProductPriceChanged events to CatalogProduct commands.

@@reventless.extension

module Mapping = {
  module ExtensionPoint = CatalogSpec.Products_ExtensionPoint
  module Delegate = CatalogProduct

  open ExtensionPoint
  open Delegate
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
