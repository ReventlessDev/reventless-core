// Maps internal Catalog events to the stable ProductsExtensionPoint public API.

open Reventless
open ReventlessInfra.ExtensionPointMapping

module ExtensionPoint = CatalogSpec.ProductsExtensionPoint

// DCB adapter: defines the event type used for outgoing event mapping.
// Only the events relevant to the extension point are included.
module Aggregate = {
  let name = "CatalogEventLog"
  module Id = Id.String
  @schema type command = unit
  @schema
  type event =
    | ProductAdded({
        productId: @s.matches(DcbTag.string) string,
        name: string,
        description: string,
        price: float,
      })
    | ProductPriceChanged({productId: @s.matches(DcbTag.string) string, price: float})
  @schema type error = unit
  let commandSchema = S.unit
  let moduleUrl: string = %raw(`import.meta.url`)
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Aggregate.ProductAdded({productId, name, price}) => [
      PublishEvent(
        productId,
        CatalogSpec.ProductsExtensionPoint.ProductBecameAvailable({productId, name, price}),
      ),
    ]
  | Aggregate.ProductPriceChanged({productId, price}) => [
      PublishEvent(productId, CatalogSpec.ProductsExtensionPoint.ProductPriceChanged({productId, price})),
    ]
  }
)
