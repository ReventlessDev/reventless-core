// Maps internal Product aggregate events to the stable ProductsExtensionPoint public API.

open ReventlessInfra.ExtensionPointMapping

module ExtensionPoint = CatalogSpec.ProductsExtensionPoint

module ProductMapping = {
  module Delegate = Product

  let mapIncomingCommand = (_id, _command, _meta) => []

  open Delegate
  open ExtensionPoint
  let mapOutgoingEvent = Some((id, event, _meta, _queryEngine) =>
    switch event {
    | Added({name, price}) => [
        PublishEvent(id, ProductBecameAvailable({productId: id, name, price})),
      ]
    | PriceUpdated({price}) => [
        PublishEvent(id, ProductPriceChanged({productId: id, price})),
      ]
    | _ => []
    }
  )
}
