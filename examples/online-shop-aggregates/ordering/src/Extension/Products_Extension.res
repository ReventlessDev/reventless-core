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
    // The contract carries the catalog's typed id; routing is by string.
    | ProductBecameAvailable({productId, name, price}) => [
        PublishAggregateCommand(productId->CatalogSpec.ProductId.toString, Sync({name, price})),
      ]
    | ProductPriceChanged({productId, price}) => [
        PublishAggregateCommand(
          productId->CatalogSpec.ProductId.toString,
          UpdatePrice({price: price}),
        ),
      ]
    }

  let mapOutgoingEvent = None
}
