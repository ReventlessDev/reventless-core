// Maps internal Catalog events to the stable Products_ExtensionPoint public API.
@@reventless.spec

module ExtensionPoint = CatalogSpec.Products_ExtensionPoint

// DCB adapter: defines the event type used for outgoing event mapping.
// Only the events relevant to the extension point are included.
// `name` MUST equal `<pluginName>DcbEventLog` so the dispatch in
// `Plugin_Callback` resolves it to the topic key `Plugin_Builder` registers
// under (`name ++ "DcbEventLog"`).
module Delegate = {
  let name = "CatalogDcbEventLog"
  @schema
  type event =
    | ProductAdded({productId: string, name: string, description: string, price: Reventless.Money.t})
    | ProductPriceChanged({productId: string, price: Reventless.Money.t})
    // Both ways off the shelf, and the way back. The mapping below is where the
    // catalog's two retirements collapse into the one fact a subscriber needs.
    | ProductArchived({productId: string})
    | ProductDiscontinued({productId: string})
    | ProductUnarchived({productId: string})
}

let mapIncomingCommand = (_id, _command, _meta) => []

// EP-side directive handler: receives Schedule.create / Schedule.delete /
// QueryEngine.operations as well as the directive itself. A real handler might
// post telemetry to an external sink, schedule a follow-up command, or query
// state. For this demo we only log; see
// `reventless-core/src/plugin/connect/PluginExtensionPoint_Plugin.res` for a canonical
// multi-capability EP-side handler.
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
  // Two internal events, one published fact. `Archived` and `Discontinued` are
  // the Catalog's vocabulary for *why* a product left the shelf; a subscriber
  // asking "can this be ordered" gets the same answer from both, and giving it
  // the distinction would publish a lifecycle rather than a capability.
  //
  // Written as two arms rather than one or-pattern because ReScript cannot bind
  // a field across inline-record constructors.
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
  }
)
