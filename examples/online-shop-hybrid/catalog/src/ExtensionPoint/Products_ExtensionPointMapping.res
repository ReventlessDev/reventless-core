// Maps internal Catalog events to the stable Products_ExtensionPoint public API.
@@reventless.spec

module ExtensionPoint = CatalogSpec.Products_ExtensionPoint

// DCB adapter carrying only the events this port maps. `name` MUST be
// `<pluginName>DcbEventLog` — `Plugin_Callback` dispatches on it.
module Delegate = {
  let name = "CatalogDcbEventLog"
  @schema
  type event =
    | ProductAdded({productId: string, name: string, description: string, price: Reventless.Money.t})
    | ProductPriceChanged({productId: string, price: Reventless.Money.t})
    // Both ways off the shelf, and the way back.
    | ProductArchived({productId: string})
    | ProductDiscontinued({productId: string})
    | ProductUnarchived({productId: string})
    // One event, not the several that move the primary. Catalog resolves which
    // picture stands and announces the conclusion, so this port never has to ask
    // whether an attachment was the first, or what a removal left behind —
    // questions a stateless mapping could not answer anyway.
    | ProductEffectiveImageChanged({
        productId: string,
        productImage?: Reventless.UploadableImage.t,
      })
}

let mapIncomingCommand = (_id, _command, _meta) => []

// EP-side directive handler — logging only here; a real one might post telemetry
// or schedule a follow-up. Canonical example: `PluginExtensionPoint_Plugin.res`.
let directiveHandler = async (
  _createSchedule: Reventless.Schedule.create,
  _deleteSchedule: Reventless.Schedule.delete,
  _queryEngine: Reventless.QueryEngine.operations,
  directive: CatalogSpec.Products_ExtensionPoint.directive,
) =>
  switch directive {
  | EmitPricingUpdate({productId, price}) =>
    Console.log(
      `[Catalog.ProductsExtensionPoint] telemetry: pricing update product=${productId} price=${price->Reventless.Money.format}`,
    )
  }

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.ProductAdded({productId, name, price}) => [
      PublishEvent(
        productId,
        CatalogSpec.Products_ExtensionPoint.ProductBecameAvailable({productId, name, price}),
      ),
    ]
  | Delegate.ProductPriceChanged({productId, price}) => [
      PublishEvent(
        productId,
        CatalogSpec.Products_ExtensionPoint.ProductPriceChanged({productId, price}),
      ),
      HandleDirective(
        directiveHandler,
        CatalogSpec.Products_ExtensionPoint.EmitPricingUpdate({productId, price}),
      ),
    ]
  // Two arms, not an or-pattern: ReScript cannot bind a field across inline-record
  // constructors.
  | Delegate.ProductArchived({productId: theId}) => [
      PublishEvent(theId, CatalogSpec.Products_ExtensionPoint.ProductWithdrawn({productId: theId})),
    ]
  | Delegate.ProductDiscontinued({productId: theId}) => [
      PublishEvent(theId, CatalogSpec.Products_ExtensionPoint.ProductWithdrawn({productId: theId})),
    ]
  | Delegate.ProductUnarchived({productId: theId}) => [
      PublishEvent(
        theId,
        CatalogSpec.Products_ExtensionPoint.ProductRelisted({productId: theId}),
      ),
    ]
  // Absence travels too. A subscriber that could only be told about pictures
  // would keep showing one the catalog no longer holds — and an order placed
  // after the last picture was removed would freeze a file that was already
  // gone, which is staleness rather than the record of a purchase.
  | Delegate.ProductEffectiveImageChanged({productId, productImage: ?productImage}) => [
      PublishEvent(
        productId,
        CatalogSpec.Products_ExtensionPoint.ProductImageChanged({
          productId,
          productImage: ?productImage,
        }),
      ),
    ]
  }
)
