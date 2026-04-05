// Maps internal Product aggregate events to the stable ProductsExtensionPoint public API.
@@reventless.spec

module ExtensionPoint = CatalogSpec.ProductsExtensionPoint
module Delegate = Product

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((id, event, _meta, _queryEngine) =>
  switch event {
  | Product.Added({name, price}) => [
      PublishEvent(id, CatalogSpec.ProductsExtensionPoint.ProductBecameAvailable({productId: id, name, price})),
    ]
  | Product.PriceUpdated({price}) => [
      PublishEvent(id, CatalogSpec.ProductsExtensionPoint.ProductPriceChanged({productId: id, price})),
    ]
  | _ => []
  }
)
