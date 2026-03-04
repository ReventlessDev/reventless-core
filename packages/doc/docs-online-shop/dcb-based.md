---
title: DCB-Based Implementation
sidebar_position: 3
---

# DCB-Based Implementation

The DCB (Dynamic Consistency Boundary) approach uses a **single shared event log** for a whole Plugin. Instead of one event stream per aggregate instance, all events from all entities live in the same log and are distinguished by **tags** — indexed fields embedded in every event payload.

A command handler reads only the events it cares about (filtered by tag), makes a decision, and appends new events while asserting that no conflicting events were written since it last read. This per-command optimistic concurrency replaces the per-instance locking of the traditional aggregate pattern.

---

## Plugin 1: Catalog

Manages the product catalogue — what is available for sale and how it is organized. In the DCB approach, all catalog events live in a single shared event log. Each entity is identified by a tag field embedded in its event payloads, which the framework uses to filter events for that specific entity when processing a command.

### Chapter: Product

A product listing with a name, description, and price. Product events are tagged by `productId`.

| State Change Slices | Commands | Events |
|---|---|---|
| `AddProduct` | `AddProduct` | `ProductAdded` |
| `ChangeProductName` | `ChangeProductName` | `ProductNameChanged` |
| `ChangeProductDescription` | `ChangeProductDescription` | `ProductDescriptionChanged` |
| `ChangeProductPrice` | `ChangeProductPrice` | `ProductPriceChanged` |

| State View Slices | Events | Read Models |
|---|---|---|
| `ProductsView` | `ProductAdded`, `ProductNameChanged`, `ProductDescriptionChanged`, `ProductPriceChanged` | `Products` |

### Chapter: Category

A named grouping of products (e.g. "Books", "Electronics"). Category events are tagged by `categoryId`. `Product` entities reference a `categoryId` by value.

| State Change Slices | Commands | Events |
|---|---|---|
| `AddCategory` | `AddCategory` | `CategoryAdded` |
| `RenameCategory` | `RenameCategory` | `CategoryRenamed` |
| `ArchiveCategory` | `ArchiveCategory` | `CategoryArchived` |

| State View Slices | Events | Read Models |
|---|---|---|
| `CategoryView` | `CategoryAdded`, `CategoryRenamed`, `CategoryArchived` | `Categories` |

### Chapter: ProductDemand

Tracks per-product order demand. Driven entirely by events arriving from Ordering's Extension Point. Demand events are tagged by `productId` — the same tag as `Product` events, so the `ProductDemandView` can combine both.

| State Change Slices | Commands | Events |
|---|---|---|
| `RecordProductDemand` | `RecordDemand`, `RevokeDemand` | `ProductDemandRecorded`, `ProductDemandRevoked` |

| State View Slices | Events | Read Models |
|---|---|---|
| `ProductDemandView` | `ProductAdded`, `ProductDemandRecorded`, `ProductDemandRevoked` | `ProductDemand` |

### Extension Point: `ProductsExtensionPoint`

Outbound API from Catalog to Ordering. Translates internal `CatalogEventLog` events into a stable public vocabulary.

| EP Event | Triggered By |
|---|---|
| `ProductBecameAvailable` | `ProductAdded` |
| `ProductPriceChanged` | `ProductPriceChanged` |

### Extension: `OrdersExtension`

Inbound subscription to Ordering's `OrdersExtensionPoint`. Routes demand events to `RecordProductDemand` slice commands.

| EP Event Received | Command Dispatched |
|---|---|
| `ItemOrdered` | `RecordDemand` |
| `ItemOrderCancelled` | `RevokeDemand` |

---

## Plugin 2: Ordering

Handles the purchase flow — who is buying and what they ordered. Customer and order events share a single event log, with each entity identified by its own tag.

### Chapter: Customer

A registered buyer with contact details and account status. Customer events are tagged by `customerId`.

| State Change Slices | Commands | Events |
|---|---|---|
| `RegisterCustomer` | `RegisterCustomer` | `CustomerRegistered` |
| `ChangeEmail` | `ChangeEmail` | `EmailChanged` |
| `ChangeAddress` | `ChangeAddress` | `AddressChanged` |
| `DeactivateCustomer` | `DeactivateCustomer` | `CustomerDeactivated` |

| State View Slices | Events | Read Models |
|---|---|---|
| `CustomersView` | `CustomerRegistered`, `EmailChanged`, `AddressChanged`, `CustomerDeactivated` | `Customers` |

### Chapter: Order

A confirmed purchase referencing product IDs and a customer. Order events are tagged by `orderId`.

| State Change Slices | Commands | Events |
|---|---|---|
| `PlaceOrder` | `PlaceOrder` | `OrderPlaced` |
| `ShipOrder` | `ShipOrder` | `OrderShipped` |
| `CancelOrder` | `CancelOrder` | `OrderCancelled` |

| State View Slices | Events | Read Models |
|---|---|---|
| `OrdersView` | `OrderPlaced`, `OrderShipped`, `OrderCancelled` | `Orders` |

---

## Cross-Plugin Integration

As with the aggregate-based approach, `Order` references products by `ProductId` — integration by ID, not by object. Each Plugin still has its own DCB event log; they communicate only through Extension Points.

---

## Implementation

The following walkthrough uses the **Catalog** Plugin from `examples/online-shop-dcb/catalog/` — the `Product` chapter with its StateChangeSlices, StateViewSlice, the `ProductDemand` chapter for demand tracking, the `ProductsExtensionPoint`, the `OrdersExtension`, and the `CatalogPlugin` that wires everything together.

### 1. DCB Event Log Spec

The event log spec defines **all events in the Plugin** — from every chapter — in a single shared type. Tag fields are annotated with `@s.matches(DcbTag.string)` so the framework can index them and filter events by entity when processing a command.

```rescript
// CatalogEventLog.res

open Reventless
@schema
type event =
  | ProductAdded({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      description: string,
      price: float,
    })
  | ProductNameChanged({productId: @s.matches(DcbTag.string) string, name: string})
  | ProductDescriptionChanged({
      productId: @s.matches(DcbTag.string) string,
      description: string,
    })
  | ProductPriceChanged({productId: @s.matches(DcbTag.string) string, price: float})
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryRenamed({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryArchived({categoryId: @s.matches(DcbTag.string) string})
  | ProductDemandRecorded({productId: @s.matches(DcbTag.string) string, orderId: string})
  | ProductDemandRevoked({productId: @s.matches(DcbTag.string) string, orderId: string})
```

All events from every chapter live in the same type. Each entity uses a different tag field name (`productId`, `categoryId`) so the framework can filter precisely per entity. `ProductDemand` events reuse the `productId` tag so the demand view can query product and demand events together in a single filtered read.

### 2. StateChangeSlices

Each command is handled by a **StateChangeSlice** — a self-contained module that defines:

- **`command`** — the command type it handles
- **`error`** — the business errors it can return
- **`decisionModel`** — the minimal state needed to validate the command
- **`initialDecisionModel`** — the starting value before any events are replayed
- **`reduce`** — how to fold relevant events into the decision model
- **`decide`** — the business rule: given the current model, accept or reject the command

#### AddProduct — creation

`AddProduct` creates a new product. The decision model only needs to know whether a product with this `productId` already exists. If it does, the command is rejected.

```rescript
// AddProduct.res

open Reventless
open CatalogEventLog

let name = "AddProduct"
module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | AddProduct({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      description: string,
      price: float,
    })

@schema
type error = | ProductAlreadyExists

type decisionModel = {exists: bool}

let initialDecisionModel = {exists: false}

let reduce = (model, event) =>
  switch event {
  | ProductAdded(_) => {exists: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | AddProduct({productId, name, description, price}) =>
    if model.exists {
      Error(ProductAlreadyExists)
    } else {
      Ok([ProductAdded({productId, name, description, price})])
    }
  }
```

The `reduce` function only reacts to `ProductAdded` — any other event in the shared log is passed through unchanged. The `decide` function checks the single `exists` flag and either returns an error or emits a `ProductAdded` event.

#### ChangeProductPrice — update with idempotency

`ChangeProductPrice` modifies an existing product's price. The decision model tracks both existence and the current price, allowing the handler to reject unknown products and skip writes when the price has not changed.

```rescript
// ChangeProductPrice.res

open Reventless
open CatalogEventLog

let name = "ChangeProductPrice"
module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | ChangeProductPrice({productId: @s.matches(DcbTag.string) string, price: float})

@schema
type error = | ProductNotFound

type decisionModel = {exists: bool, currentPrice: float}

let initialDecisionModel = {exists: false, currentPrice: 0.0}

let reduce = (model, event) =>
  switch event {
  | ProductAdded({price}) => {exists: true, currentPrice: price}
  | ProductPriceChanged({price}) => {...model, currentPrice: price}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | ChangeProductPrice({productId, price}) =>
    if !model.exists {
      Error(ProductNotFound)
    } else if price == model.currentPrice {
      Ok([]) // idempotent — price unchanged
    } else {
      Ok([ProductPriceChanged({productId, price})])
    }
  }
```

The `reduce` function reacts to both `ProductAdded` (to capture the initial price) and `ProductPriceChanged` (to track subsequent changes). Returning `Ok([])` when the price is unchanged makes the command idempotent — safe to retry without side effects.

#### RecordProductDemand — driven by an Extension

`RecordProductDemand` is not called by UI clients. It is dispatched internally by the `OrdersExtension` whenever Ordering's Extension Point emits an `ItemOrdered` or `ItemOrderCancelled` event. The decision model tracks which order IDs have already been recorded to make the operation idempotent.

```rescript
// RecordProductDemand.res

open Reventless
open CatalogEventLog

let name = "RecordProductDemand"
module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | RecordDemand({
      productId: @s.matches(DcbTag.string) string,
      orderId: string,
    })
  | RevokeDemand({
      productId: @s.matches(DcbTag.string) string,
      orderId: string,
    })

@schema
type error = unit // always succeeds — demand recording is idempotent

type decisionModel = {recordedOrderIds: array<string>}
let initialDecisionModel = {recordedOrderIds: []}

let reduce = (model, event) =>
  switch event {
  | ProductDemandRecorded({orderId}) => {
      recordedOrderIds: Array.concat(model.recordedOrderIds, [orderId]),
    }
  | ProductDemandRevoked({orderId}) => {
      recordedOrderIds: model.recordedOrderIds->Array.filter(id => id !== orderId),
    }
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | RecordDemand({productId, orderId}) =>
    if model.recordedOrderIds->Array.includes(orderId) {
      Ok([]) // idempotent
    } else {
      Ok([ProductDemandRecorded({productId, orderId})])
    }
  | RevokeDemand({productId, orderId}) =>
    if !(model.recordedOrderIds->Array.includes(orderId)) {
      Ok([]) // idempotent
    } else {
      Ok([ProductDemandRevoked({productId, orderId})])
    }
  }
```

### 3. StateViewSlices

A **StateViewSlice** builds the query-side projection. It consumes events from the shared log and emits `Set` or `Update` instructions that maintain the read store.

There are two projection actions:

- **`Set(id, state)`** — creates or fully replaces the stored state for `id`
- **`Update(id, state => state)`** — applies a partial update to the existing state for `id`

#### ProductsView

```rescript
// ProductsView.res

open Reventless.Projection
open CatalogEventLog

let name = "ProductsView"
module DcbEventLogSpec = CatalogEventLog

@schema
type event = CatalogEventLog.event

@schema
type state = {productId: string, name: string, description: string, price: float}

let project = (_, event) =>
  switch event {
  | ProductAdded({productId, name, description, price}) => [
      Set(productId, {productId, name, description, price}),
    ]
  | ProductNameChanged({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductDescriptionChanged({productId, description}) => [
      Update(productId, state => {...state, description}),
    ]
  | ProductPriceChanged({productId, price}) => [Update(productId, state => {...state, price})]
  | _ => [] // Category and demand events are not handled by this view
  }
```

`ProductAdded` uses `Set` because it establishes the full initial state for a new product. All subsequent events use `Update` because they only modify one field of an already-stored record.

#### ProductDemandView

A StateViewSlice can consume events from multiple chapters in the same shared log. `ProductDemandView` reads both `ProductAdded` (to initialise the entry with the product name) and the demand events (to maintain the order count):

```rescript
// ProductDemandView.res

open Reventless.Projection
open CatalogEventLog

let name = "ProductDemandView"
module DcbEventLogSpec = CatalogEventLog

@schema
type event = CatalogEventLog.event

@schema
type state = {productId: string, name: string, orderCount: int}

let project = (state, event) =>
  switch event {
  | ProductAdded({productId, name}) =>
    switch state {
    | None => [Set(productId, {productId, name, orderCount: 0})]
    | Some(s) => [Set(productId, {...s, name})]
    }
  | ProductDemandRecorded({productId}) =>
    switch state {
    | Some(s) => [Set(productId, {...s, orderCount: s.orderCount + 1})]
    | None => []
    }
  | ProductDemandRevoked({productId}) =>
    switch state {
    | Some(s) => [Set(productId, {...s, orderCount: max(0, s.orderCount - 1)})]
    | None => []
    }
  | _ => []
  }
```

Because `ProductDemand` events use the `productId` tag — the same tag as `Product` events — the framework delivers both event types to this slice in a single filtered read. No cross-aggregate join is needed at query time.

Unlike the aggregate-based read model, the projection logic lives directly in the slice — no separate mapping module is needed.

### 4. Extension Point

An **Extension Point** is the outbound API that Catalog publishes for other Plugins to subscribe to. It has two parts: a **spec** (the stable public contract) and a **mapping** (the translation from internal events to EP events).

The spec defines the stable public vocabulary — identical to the aggregate-based implementation because the EP contract is independent of the internal storage model:

```rescript
// ProductsExtensionPointSpec.res

let name = "Catalog.Products"

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
```

The DCB mapping wraps the shared event log as an `Aggregate` adapter module. This is required because `ExtensionPointMapping.Make` expects an aggregate-shaped spec to decode outgoing events — a lightweight structural adapter, no logic changes:

```rescript
// ProductsExtensionPointMapping.res

open Reventless
open Reventless.ExtensionPointMapping

module ExtensionPoint = ProductsExtensionPointSpec

// DCB adapter: exposes CatalogEventLog as Aggregate.Spec so ExtensionPointMapping.Make
// can decode outgoing events.
module Aggregate = {
  let name = "CatalogEventLog"
  module Id = Id.String
  @schema type command = unit
  @schema type event = CatalogEventLog.event
  @schema type error = unit
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | CatalogEventLog.ProductAdded({productId, name, price}) => [
      PublishEvent(
        productId,
        ProductsExtensionPointSpec.ProductBecameAvailable({productId, name, price}),
      ),
    ]
  | CatalogEventLog.ProductPriceChanged({productId, price}) => [
      PublishEvent(productId, ProductsExtensionPointSpec.ProductPriceChanged({productId, price})),
    ]
  | _ => []
  }
)
```

The mapping logic is the same as in the aggregate-based approach — only the `module Aggregate` declaration differs.

### 5. Extension

An **Extension** is the inbound subscription that Catalog registers to receive events from Ordering's Extension Point. The spec is a local copy of Ordering's EP contract — identical to the aggregate-based version:

```rescript
// OrdersExtensionPointSpec.res

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

The DCB extension wraps the `RecordProductDemand` slice command type in an `Aggregate` adapter module so `ExtensionMapping.Make` can encode outgoing commands:

```rescript
// OrdersExtension.res

open Reventless
open Reventless.ExtensionMapping

module Spec = OrdersExtensionPointSpec

module DemandMappingImpl = {
  module ExtensionPoint = Spec

  // DCB adapter: wraps RecordProductDemand as Aggregate.Spec so ExtensionMapping.Make
  // can encode commands routed to this StateChangeSlice.
  module Aggregate = {
    let name = RecordProductDemand.name
    module Id = Id.String
    type command = RecordProductDemand.command
    let commandSchema = RecordProductDemand.commandSchema
    @schema type event = unit // unused: mapOutgoingEvent = None
    @schema type error = unit
  }

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Spec.ItemOrdered({productId, orderId}) => [
        PublishAggregateCommand(
          productId,
          RecordProductDemand.RecordDemand({productId, orderId}),
        ),
      ]
    | Spec.ItemOrderCancelled({productId, orderId}) => [
        PublishAggregateCommand(
          productId,
          RecordProductDemand.RevokeDemand({productId, orderId}),
        ),
      ]
    }

  let mapOutgoingEvent = None
}
```

The extension file exports only the mapping implementation (`DemandMappingImpl`). The functor application and `Mappings` wrapper are built in the plugin file — the same pattern as the aggregate approach. The mapping logic — routing `ItemOrdered` to `RecordDemand` and `ItemOrderCancelled` to `RevokeDemand` — is the same as in the aggregate-based approach. Only the `module Aggregate` adapter differs.

### 6. Plugin

The plugin composes the DCB event log, all StateChangeSlices, all StateViewSlices, the Extension Point, and the Extension using any `Platform` implementation. It is a pure composition root — no business logic lives here:

```rescript
// CatalogPlugin.res

open Reventless
module Make = (Platform: Platform.T) => {
  module CatalogEventLogMaker = Platform.DcbEventLog.Make(CatalogEventLog)

  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice)

  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)

  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory)
  module RenameCategorySlice = Platform.StateChangeSlice.Make(RenameCategory)
  module ArchiveCategorySlice = Platform.StateChangeSlice.Make(ArchiveCategory)

  module CategoriesViewSlice = Platform.StateViewSlice.Make(CategoriesView)

  // Demand tracking — driven by Ordering's OrdersExtensionPoint
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)

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

  // Build the Orders extension (subscribing to Ordering's EP)
  module OrdersDemandMapping = ReventlessInfra.ExtensionMapping.Make(
    OrdersExtensionPointSpec,
    OrdersExtension.DemandMappingImpl,
  )
  module OrdersExtensionMappings = {
    module Spec = OrdersExtensionPointSpec
    module type Mapping = ReventlessInfra.ExtensionMapping.T
      with module ExtensionPoint := Spec
    let name = "CatalogDemand"
    let mappings: array<module(Mapping)> = [module(OrdersDemandMapping)]
  }
  module OrdersExtensionMaker = Platform.Extension.Make(
    OrdersExtensionPointSpec,
    OrdersExtensionMappings,
  )

  module DcbSpec = CatalogEventLog
}
```

The plugin is a pure composition root — no logic lives here. Swapping `Platform` is the only change needed to move from an in-memory test environment to a full AWS deployment.
