// Ordering's extension subscribing to Catalog's ProductsExtensionPoint.
// Routes ProductBecameAvailable / ProductPriceChanged events to SyncCatalogProduct commands.

open ReventlessInfra.ExtensionMapping

module Mapping = {
  module ExtensionPoint = CatalogSpec.ProductsExtensionPoint
  module Delegate = SyncCatalogProduct

  open ExtensionPoint
  open SyncCatalogProduct
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ProductBecameAvailable({productId, name, price}) => [
        PublishAggregateCommand(productId, SyncNewProduct({productId, name, price})),
      ]
    | ProductPriceChanged({productId, price}) => [
        PublishAggregateCommand(productId, ChangeSyncedPrice({productId, price})),
      ]
    }

  let mapOutgoingEvent = None
}
