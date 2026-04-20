// Maps internal Catalog events to the stable ProductsExtensionPoint public API.
@@reventless.spec

module ExtensionPoint = CatalogSpec.ProductsExtensionPoint

// DCB adapter: defines the event type used for outgoing event mapping.
// Only the events relevant to the extension point are included.
module Delegate = {
  let name = "Catalog"
  @schema
  type event =
    | ProductAdded({productId: string, name: string, description: string, price: float})
    | ProductPriceChanged({productId: string, price: float})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.ProductAdded({productId, name, price}) => [
      PublishEvent(
        productId,
        CatalogSpec.ProductsExtensionPoint.ProductBecameAvailable({productId, name, price}),
      ),
    ]
  | Delegate.ProductPriceChanged({productId, price}) => [
      PublishEvent(productId, CatalogSpec.ProductsExtensionPoint.ProductPriceChanged({productId, price})),
    ]
  }
)
