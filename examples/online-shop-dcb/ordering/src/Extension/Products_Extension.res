// Ordering's extension subscribing to Catalog's Products_ExtensionPoint.
// Routes ProductBecameAvailable / ProductPriceChanged events to SyncCatalogProduct commands.

@@reventless.extension

module Mapping = {
  module ExtensionPoint = CatalogSpec.Products_ExtensionPoint
  module Delegate = SyncCatalogProduct

  open ExtensionPoint
  open SyncCatalogProduct
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ProductBecameAvailable({productId, name, price}) => [
        PublishStateChangeSliceCommand(SyncNewProduct({productId, name, price})),
      ]
    | ProductPriceChanged({productId, price}) => [
        PublishStateChangeSliceCommand(ChangeSyncedPrice({productId, price})),
      ]
    }

  let mapOutgoingEvent = None
}
