// Maps internal CatalogEventLog events to the stable ProductsExtensionPoint public API.

open Reventless
open ReventlessInfra.ExtensionPointMapping

module ExtensionPoint = CatalogSpec.ProductsExtensionPoint

// DCB adapter: exposes CatalogEventLog as Aggregate.Spec so ExtensionPointMapping.Make
// can decode outgoing events. Only needed because mapOutgoingEvent is Some.
module Aggregate = {
  let name = "CatalogEventLog"
  module Id = Id.String
  @schema type command = unit
  @schema type event = CatalogEventLog.event
  @schema type error = unit
  let commandSchema = S.unit
  let moduleUrl: string = %raw(`import.meta.url`)
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | CatalogEventLog.ProductAdded({productId, name, price}) => [
      PublishEvent(
        productId,
        CatalogSpec.ProductsExtensionPoint.ProductBecameAvailable({productId, name, price}),
      ),
    ]
  | CatalogEventLog.ProductPriceChanged({productId, price}) => [
      PublishEvent(productId, CatalogSpec.ProductsExtensionPoint.ProductPriceChanged({productId, price})),
    ]
  | _ => []
  }
)
