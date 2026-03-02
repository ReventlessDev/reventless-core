# Plan: Connect Catalog and Ordering via Extension Points (Aggregate Example)

Mirrors the DCB example's `catalog-ordering-extension-points.md` but uses the **aggregate** pattern:
per-entity aggregates + read models instead of shared event logs + slices.

## Overview

| Integration | Direction | New read model | Value delivered |
|---|---|---|---|
| ProductsExtensionPoint | Catalog → Ordering | `AvailableProductsReadModel` | Ordering knows which products exist |
| OrdersExtensionPoint | Ordering → Catalog | `ProductDemandReadModel` | Catalog tracks which products are selling |

The two extension points form the same **anti-corruption layer** as the DCB example. The key
structural difference is that the aggregate pattern uses actual aggregates (with behaviors) on the
subscriber side, and read models can project from multiple aggregate sources.

---

## Key differences from the DCB plan

| Aspect | DCB | Aggregate |
|---|---|---|
| EP mapping source | Fake `module Aggregate` adapter wrapping shared event log | Real aggregate spec (`module Aggregate = Product`) |
| Subscriber writes | StateChangeSlice command | Aggregate command dispatched to its CommandTopic |
| Subscriber state | StateViewSlice | ReadModel projecting from the new aggregate |
| Cross-source read model | Not needed (shared log has all events) | ProductDemandReadModel projects from both `Product` and `ProductDemand` aggregates |

---

## Scenario A — Product Availability Guard

### Problem

`PlaceOrder` accepts any `productIds` blindly; the Ordering plugin has no knowledge of what
products exist in Catalog.

### Solution

Catalog exposes `ProductsExtensionPoint`. Ordering subscribes via `ProductsExtension`, which routes
incoming EP events to a new `CatalogProduct` aggregate. A corresponding `AvailableProductsReadModel`
projects that aggregate's events — answering "which products can I order right now?" from inside
Ordering with no cross-service query.

---

### New file: `catalog/src/ExtensionPoint/ProductsExtensionPointSpec.res`

Identical to the DCB version — the stable public API does not change:

```rescript
let name = "Catalog.Products"

@schema
type command = unit   // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
```

### New file: `catalog/src/ExtensionPoint/ProductsExtensionPointMapping.res`

In the aggregate pattern `Product` already satisfies `Aggregate.Spec` (it has `name`, `module Id`,
`type command`, `type event`, `type error`). No fake adapter is needed — use it directly:

```rescript
open Reventless
open Reventless.ExtensionPointMapping

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
```

### New file: `ordering/src/Extension/ProductsExtensionPointSpec.res`

Local copy — must match `name = "Catalog.Products"` exactly:

```rescript
let name = "Catalog.Products"

@schema
type command = unit

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
```

### New file: `ordering/src/CatalogProduct/Aggregate/CatalogProduct.res`

A lightweight aggregate in Ordering that stores synced catalog product state:

```rescript
open Reventless
module Id = Id.String

let name = "CatalogProduct"

@schema
type command =
  | SyncNewProduct({productId: string, name: string, price: float})
  | UpdateSyncedPrice({productId: string, price: float})

@schema
type event =
  | CatalogProductSynced({productId: string, name: string, price: float})
  | CatalogProductPriceUpdated({productId: string, price: float})

@schema
type error = unit  // always succeeds — sync is idempotent
```

### New file: `ordering/src/CatalogProduct/Aggregate/CatalogProductBehavior.res`

```rescript
open Reventless
open CatalogProduct

module Spec = CatalogProduct

@schema
type state = {name: string, price: float}

let resolverConfig = {Behavior.commandSchema, fields: []}

let init = event =>
  switch event {
  | CatalogProductSynced({name, price}) => {name, price}
  | CatalogProductPriceUpdated(_) =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply = (state, event) =>
  switch event {
  | CatalogProductSynced({name, price}) => {name, price}
  | CatalogProductPriceUpdated({price}) => {...state, price}
  }

let create = (command, _context, _errorHandler) =>
  switch command {
  | SyncNewProduct({productId, name, price}) => [CatalogProductSynced({productId, name, price})]
  | UpdateSyncedPrice(_) => []   // no aggregate yet — ignore (idempotent)
  }

let execute = (_state, command, _context, _errorHandler) =>
  switch command {
  | SyncNewProduct(_) => []     // already exists — idempotent
  | UpdateSyncedPrice({productId, price}) => [CatalogProductPriceUpdated({productId, price})]
  }
```

### New file: `ordering/src/CatalogProduct/ReadModel/AvailableProductsReadModel.res`

```rescript
open Reventless

let name = "AvailableProducts"

@schema
type state = {productId: string, name: string, price: float}
```

### New file: `ordering/src/CatalogProduct/ReadModel/AvailableProductsProjections.res`

```rescript
open Reventless
open Reventless.Projection

let mappings: array<module(Mappings.Make(AvailableProductsReadModel).Mapping)> = [
  module(
    struct
      module Source = CatalogProduct
      let map = (msg: Message.event'<string, CatalogProduct.event>) =>
        switch msg.event {
        | CatalogProductSynced({productId, name, price}) =>
          Set(msg.id, ({productId, name, price}: AvailableProductsReadModel.state))
        | CatalogProductPriceUpdated({price}) =>
          Update(msg.id, state => {...state, price})
        }
    end
  ),
]
```

### New file: `ordering/src/Extension/ProductsExtension.res`

Routes incoming EP events to `CatalogProduct` commands. Here `module Aggregate = CatalogProduct`
is the real aggregate spec — no adapter:

```rescript
open Reventless
open Reventless.ExtensionMapping

module Spec = ProductsExtensionPointSpec

module ProductMappingImpl = {
  module ExtensionPoint = Spec
  module Aggregate = CatalogProduct   // real aggregate spec — no adapter needed

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Spec.ProductBecameAvailable({productId, name, price}) => [
        PublishAggregateCommand(
          productId,
          CatalogProduct.SyncNewProduct({productId, name, price}),
        ),
      ]
    | Spec.ProductPriceChanged({productId, price}) => [
        PublishAggregateCommand(
          productId,
          CatalogProduct.UpdateSyncedPrice({productId, price}),
        ),
      ]
    }

  let mapOutgoingEvent = None
}

module ProductMappingT = ReventlessCore.ExtensionMapping.Make(Spec, ProductMappingImpl)

module Mappings = {
  module Spec = Spec
  module type Mapping = ReventlessCore.ExtensionMapping.T with module ExtensionPoint := Spec
  let name = "OrderingProducts"
  let mappings: array<module(Mapping)> = [module(ProductMappingT)]
}
```

### Changed: `catalog/src/CatalogPlugin.res`

Add the ProductsExtensionPoint:

```rescript
module Make = (Platform: Platform.T) => {
  // ... existing aggregates and read models ...

  // Compile the Products extension point mapping, then build the EP component
  module ProductsEPMappingT = ReventlessCore.ExtensionPointMapping.Make(
    ProductsExtensionPointSpec,
    ProductsExtensionPointMapping,
  )
  module ProductsEPMappings = {
    module Spec = ProductsExtensionPointSpec
    module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
  }
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
    ProductsExtensionPointSpec,
    ProductsEPMappings,
  )

  // extensionPoints = [module(ProductsExtensionPointMaker)]
}
```

### Changed: `ordering/src/OrderingPlugin.res`

Register the new CatalogProduct aggregate, its read model, and the ProductsExtension:

```rescript
module Make = (Platform: Platform.T) => {
  // ... existing aggregates and read models ...

  // Catalog product shadow — driven by Catalog's ProductsExtensionPoint
  module CatalogProductAggregate = Platform.Aggregate.Make(
    CatalogProduct,
    CatalogProductBehavior,
    NoEventMappings.Make(CatalogProduct),
  )

  module AvailableProductsMappings: Projection.Mappings with module Target := AvailableProductsReadModel = {
    module M = Projection.Mappings.Make(AvailableProductsReadModel)
    module type Mapping = M.Mapping
    let mappings = AvailableProductsProjections.mappings
  }
  module AvailableProductsReadModelMaker = Platform.ReadModel.Make(
    AvailableProductsReadModel,
    AvailableProductsMappings,
  )

  // Build the Products extension (subscribing to Catalog's EP)
  module ProductsExtensionMaker = ReventlessCore.Extension_Builder.Make(
    ProductsExtensionPointSpec,
    ProductsExtension.Mappings,
  )

  // extensions = [module(ProductsExtensionMaker)]
}
```

---

## Scenario B — Product Demand Tracking

### Problem

Catalog has no visibility into which products are selling.

### Solution

Ordering exposes `OrdersExtensionPoint`. Catalog subscribes, routes each `ItemOrdered`/
`ItemOrderCancelled` event to a new `ProductDemand` aggregate (keyed by `productId`), and projects
demand events into a `ProductDemandReadModel` that combines data from both the `Product` and
`ProductDemand` aggregates. This demonstrates the aggregate pattern's ability to build read models
from multiple aggregate sources.

---

### Required domain change: `ordering/src/Aggregate/Order.res`

`ItemOrderCancelled` requires knowing which products were in the cancelled order. Extend
`OrderCancelled`:

```rescript
| OrderCancelled({orderId: string, productIds: array<string>})  // productIds is new
```

### Changed: `ordering/src/Aggregate/OrderBehavior.res`

Carry `productIds` through the `Placed` state so `CancelOrder.execute` can include them:

```rescript
@schema
type state =
  | Placed({customerId: string, productIds: array<string>})
  | Shipped
  | Cancelled

// apply: Placed branch unchanged (already carries productIds)
// execute: CancelOrder now emits OrderCancelled with productIds from state
let execute = (state, command, context, errorHandler) =>
  switch (state, command) {
  // ...
  | (Placed({productIds}), CancelOrder({orderId})) =>
    [OrderCancelled({orderId, productIds})]
  // ...
  }
```

### New file: `ordering/src/ExtensionPoint/OrdersExtensionPointSpec.res`

```rescript
let name = "Ordering.Orders"

@schema
type command = unit  // read-only

@schema
type event =
  | ItemOrdered({productId: string, orderId: string, customerId: string})
  | ItemOrderCancelled({productId: string, orderId: string})

@schema
type directive = unit
```

### New file: `ordering/src/ExtensionPoint/OrdersExtensionPointMapping.res`

`module Aggregate = Order` directly. Decomposes batch product arrays into per-product EP events:

```rescript
open Reventless
open Reventless.ExtensionPointMapping

module ExtensionPoint = OrdersExtensionPointSpec

// Aggregate pattern: Order spec satisfies Aggregate.Spec directly — no adapter needed.
module Aggregate = Order

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Order.OrderPlaced({orderId, customerId, productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(
        productId,
        OrdersExtensionPointSpec.ItemOrdered({productId, orderId, customerId}),
      )
    )
  | Order.OrderCancelled({orderId, productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(
        productId,
        OrdersExtensionPointSpec.ItemOrderCancelled({productId, orderId}),
      )
    )
  | _ => []
  }
)
```

### New file: `catalog/src/Extension/OrdersExtensionPointSpec.res`

Local copy — must match `name = "Ordering.Orders"`:

```rescript
let name = "Ordering.Orders"

@schema
type command = unit

@schema
type event =
  | ItemOrdered({productId: string, orderId: string, customerId: string})
  | ItemOrderCancelled({productId: string, orderId: string})

@schema
type directive = unit
```

### New file: `catalog/src/Product/Aggregate/ProductDemand.res`

A lightweight aggregate in Catalog that records per-product order demand:

```rescript
open Reventless
module Id = Id.String

let name = "ProductDemand"

@schema
type command =
  | RecordDemand({productId: string, orderId: string})
  | RevokeDemand({productId: string, orderId: string})

@schema
type event =
  | ProductDemandRecorded({productId: string, orderId: string})
  | ProductDemandRevoked({productId: string, orderId: string})

@schema
type error = unit
```

### New file: `catalog/src/Product/Aggregate/ProductDemandBehavior.res`

```rescript
open Reventless
open ProductDemand

module Spec = ProductDemand

@schema
type state = {recordedOrderIds: array<string>}

let resolverConfig = {Behavior.commandSchema, fields: []}

let init = event =>
  switch event {
  | ProductDemandRecorded({orderId}) => {recordedOrderIds: [orderId]}
  | ProductDemandRevoked(_) =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply = (state, event) =>
  switch event {
  | ProductDemandRecorded({orderId}) =>
    {recordedOrderIds: Array.concat(state.recordedOrderIds, [orderId])}
  | ProductDemandRevoked({orderId}) =>
    {recordedOrderIds: state.recordedOrderIds->Array.filter(id => id !== orderId)}
  }

let create = (command, _context, _errorHandler) =>
  switch command {
  | RecordDemand({productId, orderId}) => [ProductDemandRecorded({productId, orderId})]
  | RevokeDemand(_) => []   // nothing recorded yet — idempotent
  }

let execute = (state, command, _context, _errorHandler) =>
  switch command {
  | RecordDemand({productId, orderId}) =>
    if state.recordedOrderIds->Array.includes(orderId) {
      []  // idempotent
    } else {
      [ProductDemandRecorded({productId, orderId})]
    }
  | RevokeDemand({productId, orderId}) =>
    if !(state.recordedOrderIds->Array.includes(orderId)) {
      []  // idempotent
    } else {
      [ProductDemandRevoked({productId, orderId})]
    }
  }
```

### New file: `catalog/src/Product/ReadModel/ProductDemandReadModel.res`

```rescript
open Reventless

let name = "ProductDemand"

@schema
type state = {productId: string, name: string, orderCount: int}
```

### New file: `catalog/src/Product/ReadModel/ProductDemandProjections.res`

Demonstrates a **multi-source read model**: projects from both `Product` and `ProductDemand`
aggregates in a single read model. The Product mapping initialises the entry; the ProductDemand
mapping updates the counter.

```rescript
open Reventless
open Reventless.Projection

module M = Mappings.Make(ProductDemandReadModel)

let mappings: array<module(M.Mapping)> = [
  // Source 1: Product aggregate — initialise the entry on ProductAdded
  module(
    struct
      module Source = Product
      let map = (msg: Message.event'<string, Product.event>) =>
        switch msg.event {
        | Product.ProductAdded({productId, name}) =>
          Set(msg.id, ({productId, name, orderCount: 0}: ProductDemandReadModel.state))
        | _ => Ignore
        }
    end
  ),
  // Source 2: ProductDemand aggregate — increment / decrement the counter
  module(
    struct
      module Source = ProductDemand
      let map = (msg: Message.event'<string, ProductDemand.event>) =>
        switch msg.event {
        | ProductDemand.ProductDemandRecorded({productId: _}) =>
          Update(msg.id, state => {...state, orderCount: state.orderCount + 1})
        | ProductDemand.ProductDemandRevoked({productId: _}) =>
          Update(msg.id, state => {...state, orderCount: max(0, state.orderCount - 1)})
        }
    end
  ),
]
```

### New file: `catalog/src/Extension/OrdersExtension.res`

Routes incoming EP events to `ProductDemand` commands. `module Aggregate = ProductDemand` is the
real aggregate spec:

```rescript
open Reventless
open Reventless.ExtensionMapping

module Spec = OrdersExtensionPointSpec

module DemandMappingImpl = {
  module ExtensionPoint = Spec
  module Aggregate = ProductDemand   // real aggregate spec — no adapter needed

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Spec.ItemOrdered({productId, orderId}) => [
        PublishAggregateCommand(
          productId,
          ProductDemand.RecordDemand({productId, orderId}),
        ),
      ]
    | Spec.ItemOrderCancelled({productId, orderId}) => [
        PublishAggregateCommand(
          productId,
          ProductDemand.RevokeDemand({productId, orderId}),
        ),
      ]
    }

  let mapOutgoingEvent = None
}

module DemandMappingT = ReventlessCore.ExtensionMapping.Make(Spec, DemandMappingImpl)

module Mappings = {
  module Spec = Spec
  module type Mapping = ReventlessCore.ExtensionMapping.T with module ExtensionPoint := Spec
  let name = "CatalogDemand"
  let mappings: array<module(Mapping)> = [module(DemandMappingT)]
}
```

### Changed: `ordering/src/OrderingPlugin.res`

Add the OrdersExtensionPoint:

```rescript
module Make = (Platform: Platform.T) => {
  // ... existing aggregates and read models ...

  // Compile the Orders extension point mapping, then build the EP component
  module OrdersEPMappingT = ReventlessCore.ExtensionPointMapping.Make(
    OrdersExtensionPointSpec,
    OrdersExtensionPointMapping,
  )
  module OrdersEPMappings = {
    module Spec = OrdersExtensionPointSpec
    module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(OrdersEPMappingT)]
  }
  module OrdersExtensionPointMaker = Platform.ExtensionPoint.Make(
    OrdersExtensionPointSpec,
    OrdersEPMappings,
  )

  // extensionPoints = [module(OrdersExtensionPointMaker)]
}
```

### Changed: `catalog/src/CatalogPlugin.res`

Register the ProductDemand aggregate, its read model, and the OrdersExtension:

```rescript
module Make = (Platform: Platform.T) => {
  // ... existing aggregates and read models ...

  // Demand tracking — driven by Ordering's OrdersExtensionPoint
  module ProductDemandAggregate = Platform.Aggregate.Make(
    ProductDemand,
    ProductDemandBehavior,
    NoEventMappings.Make(ProductDemand),
  )

  module ProductDemandMappings: Projection.Mappings with module Target := ProductDemandReadModel = {
    module M = Projection.Mappings.Make(ProductDemandReadModel)
    module type Mapping = M.Mapping
    let mappings = ProductDemandProjections.mappings
  }
  module ProductDemandReadModelMaker = Platform.ReadModel.Make(
    ProductDemandReadModel,
    ProductDemandMappings,
  )

  // Build the Orders extension (subscribing to Ordering's EP)
  module OrdersExtensionMaker = ReventlessCore.Extension_Builder.Make(
    OrdersExtensionPointSpec,
    OrdersExtension.Mappings,
  )

  // extensionPoints = [module(ProductsExtensionPointMaker)]
  // extensions     = [module(OrdersExtensionMaker)]
}
```

---

## File checklist

### Catalog package

- [x] `src/ExtensionPoint/ProductsExtensionPointSpec.res` — new
- [x] `src/ExtensionPoint/ProductsExtensionPointMapping.res` — new (uses `module Aggregate = Product` directly)
- [x] `src/Extension/OrdersExtensionPointSpec.res` — new (local copy of Ordering's EP spec)
- [x] `src/Extension/OrdersExtension.res` — new (uses `module Aggregate = ProductDemand` directly)
- [x] `src/Product/Aggregate/ProductDemand.res` — new
- [x] `src/Product/Aggregate/ProductDemandBehavior.res` — new
- [x] `src/Product/ReadModel/ProductDemandReadModel.res` — new
- [x] `src/Product/ReadModel/ProductDemandProjections.res` — new (multi-source: Product + ProductDemand)
- [x] `src/Plugin/CatalogPlugin.res` — register ProductDemand aggregate, read model, OrdersExtension, ProductsExtensionPoint

### Ordering package

- [x] `src/ExtensionPoint/OrdersExtensionPointSpec.res` — new
- [x] `src/ExtensionPoint/OrdersExtensionPointMapping.res` — new (uses `module Aggregate = Order` directly)
- [x] `src/Extension/ProductsExtensionPointSpec.res` — new (local copy of Catalog's EP spec)
- [x] `src/Extension/ProductsExtension.res` — new (uses `module Aggregate = CatalogProduct` directly)
- [x] `src/CatalogProduct/Aggregate/CatalogProduct.res` — new
- [x] `src/CatalogProduct/Aggregate/CatalogProductBehavior.res` — new
- [x] `src/CatalogProduct/ReadModel/AvailableProductsReadModel.res` — new
- [x] `src/CatalogProduct/ReadModel/AvailableProductsProjections.res` — new
- [x] `src/Aggregate/Order.res` — extend `OrderCancelled` with `productIds`
- [x] `src/Aggregate/OrderBehavior.res` — carry `productIds` in `Placed` state; emit in `CancelOrder`
- [x] `src/Plugin/OrderingPlugin.res` — register CatalogProduct aggregate, AvailableProductsReadModel, ProductsExtension, OrdersExtensionPoint
