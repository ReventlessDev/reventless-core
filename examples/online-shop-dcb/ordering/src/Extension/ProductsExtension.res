// Ordering's extension subscribing to Catalog's ProductsExtensionPoint.
// Routes ProductBecameAvailable / ProductPriceChanged events to SyncCatalogProduct commands.

open Reventless
open ReventlessInfra.ExtensionMapping

module ProductMapping = {
  module Source = CatalogSpec.ProductsExtensionPoint
  module Target = SyncCatalogProduct

  // DCB adapter: wraps SyncCatalogProduct as Aggregate.Spec so ExtensionMapping.Make
  // can encode commands routed to this StateChangeSlice.
  module Aggregate = {
    let name = Target.name
    module Id = Id.String
    type command = Target.command
    let commandSchema = Target.commandSchema
    @schema type event = unit // unused: mapOutgoingEvent = None
    @schema type error = unit
    let moduleUrl: string = %raw(`import.meta.url`)
  }

  open Source
  open Target
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
