// Maps internal Product aggregate events to the stable ProductsExtensionPoint public API.

open ReventlessInfra.ExtensionPointMapping

module ExtensionPoint = ProductsExtensionPointSpec

// Aggregate pattern: the Product spec IS the Aggregate module — no adapter required.
module Aggregate = Product

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Product.ProductAdded({productId, name, price}) => [
      PublishEvent(
        productId,
        ProductsExtensionPointSpec.ProductBecameAvailable({productId, name, price}),
      ),
    ]
  | Product.ProductPriceUpdated({productId, price}) => [
      PublishEvent(productId, ProductsExtensionPointSpec.ProductPriceChanged({productId, price})),
    ]
  | _ => []
  }
)
