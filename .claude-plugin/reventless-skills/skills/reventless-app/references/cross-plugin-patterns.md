# Cross-Plugin Communication Patterns

## Extension Point Spec (in spec package)

Lives in a separate package (e.g., `catalog-spec/`) with minimal dependencies.

```rescript
// catalog-spec/src/ProductsExtensionPoint.res

let name = "Catalog.Products"
let moduleUrl: string = %raw(`import.meta.url`)

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
```

## Extension Point Mapping — Aggregate Approach

Maps internal aggregate events to the public extension point API.

```rescript
// catalog/src/ExtensionPoint/ProductsExtensionPoint.res

open ReventlessInfra.ExtensionPointMapping

module ExtensionPoint = CatalogSpec.ProductsExtensionPoint

module ProductMapping = {
  module Aggregate = Product  // the aggregate spec

  let mapIncomingCommand = (_id, _command, _meta) => []

  open Aggregate
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
```

## Extension Point Mapping — DCB Approach (Shim Pattern)

DCB needs a shim module exposing the event log as an `Aggregate.Spec`:

```rescript
// catalog/src/ExtensionPoint/ProductsExtensionPointMapping.res

open Reventless
open ReventlessInfra.ExtensionPointMapping

module ExtensionPoint = CatalogSpec.ProductsExtensionPoint

// DCB shim: expose event log events as an Aggregate.Spec
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
    | ProductPriceChanged({
        productId: @s.matches(DcbTag.string) string,
        price: float,
      })
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
      PublishEvent(
        productId,
        CatalogSpec.ProductsExtensionPoint.ProductPriceChanged({productId, price}),
      ),
    ]
  }
)
```

## Extension — Subscribing to Another Plugin

### Aggregate Target

```rescript
// ordering/src/Extension/ProductsExtension.res

open Reventless
open ReventlessInfra.ExtensionMapping

module ProductMapping = {
  module Source = CatalogSpec.ProductsExtensionPoint
  module Target = CatalogProduct  // local aggregate

  module Aggregate = CatalogProduct  // same as Target

  open Source
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ProductBecameAvailable({productId, name, price}) => [
        PublishAggregateCommand(productId, Sync({name, price})),
      ]
    | ProductPriceChanged({productId, price}) => [
        PublishAggregateCommand(productId, UpdatePrice({price})),
      ]
    }

  let mapOutgoingEvent = None
}
```

### DCB Target (Shim Pattern)

```rescript
// ordering/src/Extension/ProductsExtension.res

open Reventless
open ReventlessInfra.ExtensionMapping

module ProductMapping = {
  module Source = CatalogSpec.ProductsExtensionPoint
  module Target = SyncCatalogProduct  // StateChangeSlice

  // DCB shim: wrap slice as Aggregate.Spec for command encoding
  module Aggregate = {
    let name = Target.name
    module Id = Id.String
    type command = Target.command
    let commandSchema = Target.commandSchema
    @schema type event = unit
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
```

## Wiring in Plugin Composition

### Extension Point Wiring

```rescript
// In PluginPlugin.res Make functor:

// 1. Compile EP mapping
module ProductsEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
  CatalogSpec.ProductsExtensionPoint,
  ProductsExtensionPointMapping,  // or ProductsExtensionPoint.ProductMapping
)

// 2. Bundle mappings
module ProductsEPMappings = {
  module Spec = CatalogSpec.ProductsExtensionPoint
  module type Mapping = ReventlessInfra.ExtensionPointMapping.T
    with module ExtensionPoint := Spec
  let name = "ProductsEPMappings"
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
}

// 3. Build EP component
module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
  CatalogSpec.ProductsExtensionPoint,
  ProductsEPMappings,
)
```

### Extension Wiring

```rescript
// 1. Compile extension mapping
module OrdersDemandMapping = ReventlessInfra.ExtensionMapping.Make(
  OrderingSpec.OrdersExtensionPoint,
  OrdersExtension.DemandMapping,
)

// 2. Bundle mappings
module OrdersExtensionMappings = {
  module Spec = OrderingSpec.OrdersExtensionPoint
  module type Mapping = ReventlessInfra.ExtensionMapping.T
    with module ExtensionPoint := Spec
  let name = "CatalogDemand"
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(OrdersDemandMapping)]
}

// 3. Build extension component
module OrdersExtensionMaker = Platform.Extension.Make(
  OrderingSpec.OrdersExtensionPoint,
  OrdersExtensionMappings,
)
```

### Pass to Plugin.make

```rescript
Platform.Plugin.make(
  ...
  ~extensionPoints=[module(ProductsExtensionPointMaker)],
  ~extensions=[module(OrdersExtensionMaker)],
  ...
)
```
