# Plan: Connect Catalog and Ordering via Extension Points

Two natural integration points emerge from the domain. Both use the same pattern: one plugin
exposes an extension point, the other subscribes via an extension and maintains a local DCB slice.

## Overview

| Integration | Direction | New read model | Value delivered |
|---|---|---|---|
| ProductsExtensionPoint | Catalog → Ordering | `AvailableProductsView` | Ordering knows which products exist |
| OrdersExtensionPoint | Ordering → Catalog | `ProductDemandView` | Catalog tracks which products are selling |

The two extension points together form a proper **anti-corruption layer** between the bounded
contexts. Each plugin stays internally consistent and only communicates via stable, deliberately
designed contracts. For example, Catalog's internal `ProductDescriptionUpdated` event is never
visible to Ordering — only what is explicitly published through `ProductsExtensionPoint`.

---

## Scenario A — Product Availability Guard

### Problem

When a customer places an order, the Ordering plugin has no idea whether the referenced products
actually exist in the Catalog. `PlaceOrder` currently accepts any `productIds` array blindly.

### Solution

Catalog exposes a `ProductsExtensionPoint`. Ordering subscribes and builds a local shadow of
catalog products inside its own DCB event log. This shadow powers availability queries and enables
API-layer validation before order placement.

### New file: `catalog/src/ExtensionPoint/ProductsExtensionPointSpec.res`

```rescript
let name = "Catalog.Products"

@schema
type command = unit   // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type callCommand = unit
```

The EP omits category events and description updates — those are not relevant to order-taking.

### New file: `catalog/src/ExtensionPoint/ProductsExtensionPointMapping.res`

Translates internal `CatalogEventLog` events into the stable public contract:

```rescript
module ExtensionPoint = ProductsExtensionPointSpec

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((id, event, _meta, _pluginDef) =>
  switch event {
  | CatalogEventLog.ProductAdded({productId, name, price}) => [
      PublishEvent(productId, ProductsExtensionPointSpec.ProductBecameAvailable({productId, name, price}))
    ]
  | CatalogEventLog.ProductPriceUpdated({productId, price}) => [
      PublishEvent(productId, ProductsExtensionPointSpec.ProductPriceChanged({productId, price}))
    ]
  | _ => []
  }
)
```

### Changed: `ordering/src/Plugin/OrderingEventLog.res`

Add two new events (tagged by `productId`) to track the synced catalog state:

```rescript
| CatalogProductSynced({
    productId: @s.matches(Reventless.DcbTag.string) string,
    name: string,
    price: float,
  })
| CatalogProductPriceUpdated({
    productId: @s.matches(Reventless.DcbTag.string) string,
    price: float,
  })
```

### New file: `ordering/src/CatalogProduct/StateChangeSlice/SyncCatalogProduct.res`

```rescript
let name = "SyncCatalogProduct"
module DcbEventLogSpec = OrderingEventLog

@schema
type command =
  | SyncNewProduct({
      productId: @s.matches(Reventless.DcbTag.string) string,
      name: string,
      price: float,
    })
  | UpdateSyncedPrice({
      productId: @s.matches(Reventless.DcbTag.string) string,
      price: float,
    })

@schema
type error = unit  // always succeeds — sync is idempotent

type decisionModel = {name: string, price: float}
let initialDecisionModel = {name: "", price: 0.0}

let reduce = (model, event) =>
  switch event {
  | CatalogProductSynced({name, price}) => {name, price}
  | CatalogProductPriceUpdated({price}) => {...model, price}
  | _ => model
  }

let decide = (_model, command) =>
  switch command {
  | SyncNewProduct({productId, name, price}) =>
    Ok([CatalogProductSynced({productId, name, price})])
  | UpdateSyncedPrice({productId, price}) =>
    Ok([CatalogProductPriceUpdated({productId, price})])
  }
```

### New file: `ordering/src/CatalogProduct/StateViewSlice/AvailableProductsView.res`

```rescript
module DcbEventLogSpec = OrderingEventLog

@schema
type state = {productId: string, name: string, price: float}

let project = (state, event) =>
  switch event {
  | OrderingEventLog.CatalogProductSynced({productId, name, price}) =>
    Set({productId, name, price})
  | OrderingEventLog.CatalogProductPriceUpdated({price}) =>
    switch state {
    | Some(p) => Set({...p, price})
    | None => Ignore
    }
  | _ => Ignore
  }
```

This read model answers "which products can I order right now?" directly from the Ordering plugin —
no cross-service query at runtime.

### New file: `ordering/src/Extension/ProductsExtension.res`

```rescript
module Spec = ProductsExtensionPointSpec

module ProductMapping = {
  module ExtensionPoint = Spec
  module Aggregate = SyncCatalogProduct

  let aggregateName = SyncCatalogProduct.name

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Spec.ProductBecameAvailable({productId, name, price}) => [
        PublishAggregateCommand(
          productId,
          SyncCatalogProduct.SyncNewProduct({productId, name, price}),
        )
      ]
    | Spec.ProductPriceChanged({productId, price}) => [
        PublishAggregateCommand(
          productId,
          SyncCatalogProduct.UpdateSyncedPrice({productId, price}),
        )
      ]
    }

  let mapOutgoingEvent = None
}

module Mappings = {
  module Spec = Spec
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
  let name = "OrderingProducts"
  let mappings: array<module(Mapping)> = [module(ProductMapping)]
}
```

### Note on `PlaceOrder` validation

`AvailableProductsView` enables pre-validation at the API layer before dispatching `PlaceOrder`.
Full DCB-level enforcement *inside* `PlaceOrder`'s decision model would require the framework to
support querying multiple DCB tags simultaneously (orderId + each productId). That is a natural
follow-up if the framework grows to support composite tag sets; the read model approach is the
correct starting point.

---

## Scenario B — Product Demand Tracking

### Problem

The catalog team has no visibility into which products are selling. They manage prices and
descriptions in the dark.

### Solution

Ordering exposes an `OrdersExtensionPoint`. The key design insight is to *decompose* the
`OrderPlaced` event (which carries an array of productIds) into per-product `ItemOrdered` events,
giving Catalog a clean per-product stream to project.

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
type callCommand = unit
```

### Required domain change: `ordering/src/Plugin/OrderingEventLog.res`

`ItemOrderCancelled` requires knowing which products were in the cancelled order. Extend the
`OrderCancelled` event:

```rescript
| OrderCancelled({
    orderId: @s.matches(Reventless.DcbTag.string) string,
    productIds: array<string>,   // new field
  })
```

This is a legitimate domain fact: a cancellation is meaningless without knowing *what* was
cancelled. `CancelOrder`'s `decide` already has `productIds` available in its decision model
(reduced from `OrderPlaced`), so this is a straightforward addition.

### New file: `ordering/src/ExtensionPoint/OrdersExtensionPointMapping.res`

The decomposition from batch to per-product happens here:

```rescript
module ExtensionPoint = OrdersExtensionPointSpec

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((id, event, _meta, _pluginDef) =>
  switch event {
  | OrderingEventLog.OrderPlaced({orderId, customerId, productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(productId, OrdersExtensionPointSpec.ItemOrdered({productId, orderId, customerId}))
    )
  | OrderingEventLog.OrderCancelled({orderId, productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(productId, OrdersExtensionPointSpec.ItemOrderCancelled({productId, orderId}))
    )
  | _ => []
  }
)
```

One `OrderPlaced` with three products produces three `ItemOrdered` events — each tagged by
`productId`. This routing key is exactly what Catalog needs to update per-product counters.

### Changed: `catalog/src/Plugin/CatalogEventLog.res`

Add two new events for demand tracking:

```rescript
| ProductDemandRecorded({
    productId: @s.matches(Reventless.DcbTag.string) string,
    orderId: string,
  })
| ProductDemandRevoked({
    productId: @s.matches(Reventless.DcbTag.string) string,
    orderId: string,
  })
```

### New file: `catalog/src/Product/StateChangeSlice/RecordProductDemand.res`

```rescript
let name = "RecordProductDemand"
module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | RecordDemand({
      productId: @s.matches(Reventless.DcbTag.string) string,
      orderId: string,
    })
  | RevokeDemand({
      productId: @s.matches(Reventless.DcbTag.string) string,
      orderId: string,
    })

@schema
type error = unit

type decisionModel = {recordedOrderIds: array<string>}
let initialDecisionModel = {recordedOrderIds: []}

let reduce = (model, event) =>
  switch event {
  | ProductDemandRecorded({orderId}) =>
    {recordedOrderIds: Array.concat(model.recordedOrderIds, [orderId])}
  | ProductDemandRevoked({orderId}) =>
    {recordedOrderIds: model.recordedOrderIds->Array.filter(id => id !== orderId)}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | RecordDemand({productId, orderId}) =>
    if model.recordedOrderIds->Array.includes(orderId) {
      Ok([])  // idempotent
    } else {
      Ok([ProductDemandRecorded({productId, orderId})])
    }
  | RevokeDemand({productId, orderId}) =>
    if !(model.recordedOrderIds->Array.includes(orderId)) {
      Ok([])  // idempotent
    } else {
      Ok([ProductDemandRevoked({productId, orderId})])
    }
  }
```

### New file: `catalog/src/Product/StateViewSlice/ProductDemandView.res`

```rescript
module DcbEventLogSpec = CatalogEventLog

@schema
type state = {productId: string, name: string, orderCount: int}

let project = (state, event) =>
  switch event {
  | CatalogEventLog.ProductAdded({productId, name}) =>
    switch state {
    | None => Set({productId, name, orderCount: 0})
    | Some(s) => Set({...s, name})
    }
  | CatalogEventLog.ProductDemandRecorded(_) =>
    switch state {
    | Some(s) => Set({...s, orderCount: s.orderCount + 1})
    | None => Ignore
    }
  | CatalogEventLog.ProductDemandRevoked(_) =>
    switch state {
    | Some(s) => Set({...s, orderCount: max(0, s.orderCount - 1)})
    | None => Ignore
    }
  | _ => Ignore
  }
```

This is a pure projection — no cross-plugin queries, no runtime coupling.

### New file: `catalog/src/Extension/OrdersExtension.res`

```rescript
module Spec = OrdersExtensionPointSpec

module DemandMapping = {
  module ExtensionPoint = Spec
  module Aggregate = RecordProductDemand

  let aggregateName = RecordProductDemand.name

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Spec.ItemOrdered({productId, orderId}) => [
        PublishAggregateCommand(
          productId,
          RecordProductDemand.RecordDemand({productId, orderId}),
        )
      ]
    | Spec.ItemOrderCancelled({productId, orderId}) => [
        PublishAggregateCommand(
          productId,
          RecordProductDemand.RevokeDemand({productId, orderId}),
        )
      ]
    }

  let mapOutgoingEvent = None
}

module Mappings = {
  module Spec = Spec
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
  let name = "CatalogDemand"
  let mappings: array<module(Mapping)> = [module(DemandMapping)]
}
```

---

## Plugin registration changes

### `CatalogPlugin.res`

```rescript
module Make = (Platform: ReventlessSpec.Platform.T) => {
  // ... existing slices ...

  // New demand tracking
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)

  // extensionPoints = [module(ProductsExtensionPointMapping)]
  // extensions     = [module(OrdersExtension)]

  module DcbSpec = CatalogEventLog
}
```

### `OrderingPlugin.res`

```rescript
module Make = (Platform: ReventlessSpec.Platform.T) => {
  // ... existing slices ...

  // New catalog product shadow
  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(SyncCatalogProduct)
  module AvailableProductsViewSlice = Platform.StateViewSlice.Make(AvailableProductsView)

  // extensionPoints = [module(OrdersExtensionPointMapping)]
  // extensions     = [module(ProductsExtension)]

  module DcbSpec = OrderingEventLog
}
```

---

## File checklist

### Catalog package

- [ ] `src/ExtensionPoint/ProductsExtensionPointSpec.res` — new
- [ ] `src/ExtensionPoint/ProductsExtensionPointMapping.res` — new
- [ ] `src/Extension/OrdersExtension.res` — new
- [ ] `src/Product/StateChangeSlice/RecordProductDemand.res` — new
- [ ] `src/Product/StateViewSlice/ProductDemandView.res` — new
- [ ] `src/Plugin/CatalogEventLog.res` — add `ProductDemandRecorded`, `ProductDemandRevoked`
- [ ] `src/Plugin/CatalogPlugin.res` — register new slices, extension point, extension

### Ordering package

- [ ] `src/ExtensionPoint/OrdersExtensionPointSpec.res` — new
- [ ] `src/ExtensionPoint/OrdersExtensionPointMapping.res` — new
- [ ] `src/Extension/ProductsExtension.res` — new
- [ ] `src/CatalogProduct/StateChangeSlice/SyncCatalogProduct.res` — new
- [ ] `src/CatalogProduct/StateViewSlice/AvailableProductsView.res` — new
- [ ] `src/Plugin/OrderingEventLog.res` — add catalog sync events; extend `OrderCancelled`
- [ ] `src/Plugin/OrderingPlugin.res` — register new slices, extension point, extension
