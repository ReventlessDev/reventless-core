// Maps internal Catalog events to the stable Products_ExtensionPoint public API.
@@reventless.spec

module ExtensionPoint = CatalogSpec.Products_ExtensionPoint

// DCB adapter carrying only the events this port maps. `name` MUST be
// `<pluginName>DcbEventLog` — `Plugin_Callback` dispatches on it.
module Delegate = {
  let name = "CatalogDcbEventLog"
  @schema
  type event =
    | ProductAdded({
        productId: CatalogSpec.ProductId.t,
        name: string,
        description: string,
        price: float,
      })
    | ProductPriceChanged({productId: CatalogSpec.ProductId.t, price: float})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some(
  (_id, event, _meta, _queryEngine) =>
    switch event {
    // Publishing routes by string; the contract carries the typed id.
    | Delegate.ProductAdded({productId, name, price}) => [
        PublishEvent(
          productId->CatalogSpec.ProductId.toString,
          CatalogSpec.Products_ExtensionPoint.ProductBecameAvailable({productId, name, price}),
        ),
      ]
    | Delegate.ProductPriceChanged({productId, price}) => [
        PublishEvent(
          productId->CatalogSpec.ProductId.toString,
          CatalogSpec.Products_ExtensionPoint.ProductPriceChanged({productId, price}),
        ),
      ]
    },
)
