# Platform & Plugin Guide

This guide walks through building platforms with plugins using Reventless. It covers both the **aggregate** and **DCB** (Dynamic Consistency Boundary) approaches, using the **online-shop** examples (`examples/online-shop-aggregates/`, `examples/online-shop-dcb/`).

---

## Table of Contents

1. [Overview](#overview)
2. [Package Structure](#package-structure)
3. [Spec Packages](#spec-packages)
4. [Aggregate Approach](#aggregate-approach)
   - [Aggregates](#aggregates)
   - [Behaviors](#behaviors)
   - [Read Models](#read-models)
   - [Projections](#projections)
   - [Extension Points](#extension-points)
   - [Extensions](#extensions)
   - [Plugin Composition](#plugin-composition)
5. [DCB Approach](#dcb-approach)
   - [DCB Event Log](#dcb-event-log)
   - [StateChangeSlice](#statechangeslice)
   - [StateViewSlice](#stateviewslice)
   - [DCB Plugin Composition](#dcb-plugin-composition)
   - [DCB Extension Point / Extension Adapter Pattern](#dcb-extension-point--extension-adapter-pattern)
   - [DCB Directory Layout](#dcb-directory-layout)
   - [DCB Package Structure](#dcb-package-structure)
   - [DCB Platform Package](#dcb-platform-package)
6. [Hybrid Composition](#hybrid-composition)
   - [When to Use Each Approach](#when-to-use-each-approach)
   - [Hybrid Plugin Composition](#hybrid-plugin-composition)
   - [ReadModel Sourcing from DCB EventTopic](#readmodel-sourcing-from-dcb-eventtopic)
   - [Extension Points in Hybrid Plugins](#extension-points-in-hybrid-plugins)
   - [Directory Layout](#directory-layout)
   - [Reference Example](#reference-example)
7. [Platform Package](#platform-package)
8. [Configuration Reference](#configuration-reference)
   - [Split API Mode](#split-api-mode)
9. [Cross-Plugin Communication](#cross-plugin-communication)
10. [AutoUI](#autoui)
11. [Conventions & Pitfalls](#conventions--pitfalls)

---

## Overview

A Reventless **platform** is a deployable application composed of one or more **plugins**. Each plugin owns a bounded context and can be built using either the **aggregate** approach, the **DCB** approach, or a hybrid of both.

```
Platform
├── Plugin A  (aggregate approach)
│   ├── Aggregates + Behaviors  (write-side: per-entity event streams)
│   ├── Read Models + Projections  (query-side: projected from aggregate events)
│   ├── Extension Points  (outbound: publish events to other plugins)
│   └── Extensions        (inbound: subscribe to events from other plugins)
├── Plugin B  (DCB approach)
│   ├── StateChangeSlices  (write-side: shared event log, entity-tagged)
│   ├── StateViewSlices    (query-side: projected from shared log)
│   ├── Extension Points
│   └── Extensions
└── Plugin C  (hybrid)
    └── mix of both
```

Plugins never depend on each other directly. Cross-plugin communication flows through **extension points** — stable public APIs that decouple the publisher from all subscribers.

| | Aggregate | DCB |
|---|---|---|
| Event storage | One stream per entity instance | One shared log per bounded context |
| Write-side | `Behavior` (`initialState`/`evolve`/`decide`) | `StateChangeSlice` (`initialState`/`evolve`/`decide`) |
| Read-side | `ReadModel` + `Projection` mappings | `StateViewSlice` (`project`) |
| Entity filtering | Implicit (stream scoped to ID) | Explicit (`@s.matches(DcbTag.string)` on entity ID fields) |
| Best for | Self-contained entities with clear lifecycle | Commands that span multiple entity types |

---

## Package Structure

Each platform lives in a root folder containing five kinds of packages:

```
online-shop-aggregates/
├── catalog-spec/          # Spec package — extension point type definitions
│   ├── package.json
│   ├── rescript.json
│   └── src/
│       └── ProductsExtensionPoint.res
├── ordering-spec/         # Spec package
│   └── ...
├── catalog/               # Plugin package — full implementation
│   ├── package.json
│   ├── rescript.json
│   └── src/
│       ├── Aggregate/
│       ├── ReadModel/
│       ├── ExtensionPoint/
│       ├── Extension/
│       └── Plugin.res                    # Auto-generated composition root
├── ordering/              # Plugin package
│   └── ...
└── online-shop-aggregates/ # Platform package — wires plugins together
    ├── package.json
    ├── rescript.json
    └── src/
        └── Main.res
```

**Why separate spec packages?** Plugins need to reference each other's extension point types for cross-plugin communication, but direct plugin-to-plugin dependencies create circular dependency cycles. Spec packages contain only type definitions and break the cycle.

---

## Spec Packages

A spec package defines the **public API** of one plugin's extension points. It contains only type definitions — no behavior, no infrastructure.

### File: `ProductsExtensionPoint.res`

```rescript
// Stable public API from the Catalog plugin
@@reventless.spec

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
```

The PPX derives the dotted name `"Catalog.Products"` automatically from the `CatalogSpec` namespace + filename `ProductsExtensionPoint.res` (strips `ExtensionPoint` → `"Products"`, strips `Spec` from namespace → `"Catalog"`).

Each extension point spec defines:

| Field | Purpose |
|-------|---------|
| `command` | Inbound commands other plugins can send (use `unit` for read-only) |
| `event` | Outbound events published to subscribers |
| `directive` | Out-of-band instructions (use `unit` when not needed) |

All types use `@schema` (sury-ppx) for automatic JSON serialization.

### Configuration

**`package.json`**:
```json
{
  "name": "@reventlessdev/online-shop-aggregates-catalog-spec",
  "dependencies": {
    "sury": "^11.0.0-alpha.4",
    "@reventlessdev/reventless-spec": "*"
  },
  "devDependencies": {
    "rescript": "^12.1.0",
    "sury-ppx": "^11.0.0-alpha.2"
  }
}
```

**`rescript.json`**:
```json
{
  "name": "@reventlessdev/online-shop-aggregates-catalog-spec",
  "namespace": "CatalogSpec",
  "ppx-flags": ["@reventlessdev/reventless-ppx/bin", "sury-ppx/bin"],
  "sources": [{"dir": "src", "subdirs": true}],
  "dependencies": ["sury"]
}
```

Key points:
- **Minimal dependencies** — only `sury` (no `reventless-spec` needed for EP specs)
- **Explicit namespace ending in `Spec`** (e.g., `CatalogSpec`) — the PPX uses this to derive dotted EP names
- **PPX ordering**: `reventless-ppx` must come before `sury-ppx` (injects annotations that sury then processes)
- Other packages reference types as `CatalogSpec.ProductsExtensionPoint`

---

## Aggregate Approach

In the aggregate approach each entity has its own private event stream. Commands are processed by a **Behavior** that reconstructs full entity state from that stream. The query side is handled by **Read Models** fed by **Projection** mappings. Use this approach when entities are self-contained with clear lifecycle state machines.

A plugin package implements a bounded context. It contains aggregates, behaviors, read models, projections, extension points, extensions, and a composition root.

### Directory layout

```
catalog/
└── src/
    ├── Aggregate/
    │   ├── Product.res              # Aggregate spec (types)
    │   ├── ProductBehavior.res      # Aggregate behavior (state machine)
    │   ├── Category.res
    │   ├── CategoryBehavior.res
    │   ├── ProductDemand.res        # Extension-driven aggregate
    │   └── ProductDemandBehavior.res
    ├── ReadModel/
    │   ├── ProductsReadModel.res    # Read model spec (state shape)
    │   ├── ProductsProjections.res  # Projection mappings
    │   ├── CategoriesReadModel.res
    │   ├── CategoriesProjections.res
    │   ├── ProductDemandReadModel.res
    │   └── ProductDemandProjections.res
    ├── ExtensionPoint/
    │   └── ProductsExtensionPoint.res  # Maps aggregate events → EP events
    ├── Extension/
    │   └── OrdersExtension.res         # Maps EP events → aggregate commands
    └── Plugin.res                      # Auto-generated composition root
```

---

### Aggregates

An aggregate spec defines the command/event vocabulary and error types.

**`Product.res`** (aggregate spec):
```rescript
@@reventless.spec

@schema
type command =
  | Add({name: string, description: string, price: float})
  | UpdateName({name: string})
  | UpdateDescription({description: string})
  | UpdatePrice({price: float})

@schema
type event =
  | Added({name: string, description: string, price: float})
  | NameUpdated({name: string})
  | DescriptionUpdated({description: string})
  | PriceUpdated({price: float})

@schema
type error =
  | ProductAlreadyExists
  | ProductNotFound
```

The `@@reventless.spec` PPX annotation auto-injects:
- **`let name = "Product"`** — derived from filename (`Product.res` → `"Product"`)
- **`module Id = Reventless.Id.String`** — default aggregate identity type
- **`let moduleUrl`** — npm specifier for runtime dynamic imports

Use `@@reventless.spec("CustomName")` to override the derived name.

Conventions:
- Commands are **imperative** (`Add`, `UpdateName`), events are **past tense** (`Added`, `NameUpdated`)
- All types use `@schema` for serialization
- Error variants for domain validation failures

#### Command Channel Configuration

By default all aggregates use `CommandTopicChannel.SQS_Sync` — a standard SQS queue where the handler runs inline during the mutation, so the client receives an immediate `CommandResult`:

```graphql
# All mutations return the same union regardless of channel
mutation AddProduct($id: ID!, $name: String!) {
  addProduct(id: $id, name: $name) {
    __typename
    ... on CommandAccepted { msgId entityId eventCount }
    ... on CommandRejected { msgId errorCode errorDetail }
    ... on CommandPending  { msgId }
  }
}
```

For high-contention aggregates where FIFO ordering is more important than synchronous results, opt in to the async channel:

```rescript
// Explicit opt-in — async channel, returns CommandPending
module InventoryAggregate = Platform.Aggregate.Make(
  Inventory,
  InventoryBehavior,
  ReventlessInfra.NoEventMappings.Make(Inventory),
  // ~commandTopicChannel=CommandTopicChannel.SQS_Async,  // (future: per-aggregate channel override)
)
```

| Channel | Queue | Mutation result | Use when |
|---------|-------|----------------|----------|
| `SQS_Sync` (default) | Standard SQS | `CommandAccepted` \| `CommandRejected` | User-facing CRUD, payment commands |
| `SQS_Async` | FIFO SQS | `CommandPending` | High-contention writes, internal automation |

---

### Behaviors

A behavior implements the aggregate state machine: state evolution from events, and command decisions.

**`ProductBehavior.res`**:
```rescript
@@reventless.behavior

@schema
type state = {name: string, description: string, price: float}

let initialState = {name: "", description: "", price: 0.0}

// Evolve state from events
let evolve = (state, event) =>
  switch event {
  | Added({name, description, price}) => {name, description, price}
  | NameUpdated({name}) => {...state, name}
  | DescriptionUpdated({description}) => {...state, description}
  | PriceUpdated({price}) => {...state, price}
  }

// Decide on commands: return Ok(events) or Error(error)
let decide = (state, command) =>
  switch command {
  | Add({name, description, price}) if state.name == "" =>
    Ok([Added({name, description, price})])
  | Add(_) => Error(ProductAlreadyExists)
  | UpdateName({name}) if name == state.name => Ok([])         // idempotent
  | UpdateName({name}) => Ok([NameUpdated({name: name})])
  | UpdateDescription({description}) if description == state.description => Ok([])
  | UpdateDescription({description}) => Ok([DescriptionUpdated({description: description})])
  | UpdatePrice({price}) if price == state.price => Ok([])
  | UpdatePrice({price}) => Ok([PriceUpdated({price: price})])
  }
```

**Three behavior definitions:**

| Definition | Purpose | Type |
|------------|---------|------|
| `initialState` | Starting state before any events | `state` |
| `evolve` | Fold events into state | `(state, event) => state` |
| `decide` | Accept or reject a command | `(state, command) => result<array<event>, error>` |

**Idempotency pattern:** Return `Ok([])` (empty event list) when a command would produce no change. This makes retries safe.

**Error handling:** Return `Error(error)` for domain violations. The framework routes errors to the caller.

---

### Read Models

A read model defines the query-side state shape.

**`ProductsReadModel.res`**:
```rescript
@@reventless.spec

@schema
type state = {
  productId: string,
  name: string,
  description: string,
  price: float,
}

open Reventless.ReadModel
let config = config()
let subIdConfig = None
```

The PPX derives `let name = "Products"` from the filename (`ProductsReadModel.res` → strips `ReadModel` → `"Products"`).

- **`state`** — the record stored per entity in the query database
- **`config`** — default configuration (pagination, etc.)
- **`subIdConfig`** — for sub-entity read models (`None` for top-level)

---

### Projections

Projections map aggregate events to read model state changes.

**`ProductsProjections.res`** (single-source):
```rescript
open Reventless.Message
open Reventless.Projection

module ProductMapping = Mapping.Make(
  Product,           // Source aggregate
  ProductsReadModel, // Target read model
  {
    open Product     // Open aggregate for unqualified event access
    let project = ({event, id, _}) =>
      switch event {
      | Added({name, description, price}) =>
        Set(id, {ProductsReadModel.productId: id, name, description, price})
      | NameUpdated({name}) => Update(id, state => {...state, name})
      | DescriptionUpdated({description}) => Update(id, state => {...state, description})
      | PriceUpdated({price}) => Update(id, state => {...state, price})
      }
  },
)
```

**Projection operations:**

| Operation | Purpose |
|-----------|---------|
| `Set(id, state)` | Create or replace the entire record |
| `Update(id, state => newState)` | Partially update an existing record |
| `Ignore` | Skip this event |

**Multi-source projections** — when a read model combines events from multiple aggregates, define one mapping per source:

**`ProductDemandProjections.res`**:
```rescript
open Reventless.Message
open Reventless.Projection

module ProductMapping = Mapping.Make(
  Product,
  ProductDemandReadModel,
  {
    open Product
    let project = ({event, id, _}) =>
      switch event {
      | Added({name}) =>
        Set(id, {ProductDemandReadModel.productId: id, name, orderCount: 0})
      | _ => Ignore
      }
  },
)

module ProductDemandMapping = Mapping.Make(
  ProductDemand,
  ProductDemandReadModel,
  {
    open ProductDemand
    let project = ({event, id, _}) =>
      switch event {
      | Recorded(_) =>
        Update(id, (state: ProductDemandReadModel.state) => {
          ...state, orderCount: state.orderCount + 1
        })
      | Revoked(_) =>
        Update(id, (state: ProductDemandReadModel.state) => {
          ...state, orderCount: max(0, state.orderCount - 1)
        })
      }
  },
)
```

When the target read model type is ambiguous in the `Update` callback, annotate the `state` parameter: `(state: ProductDemandReadModel.state)`.

---

### Extension Points

An extension point maps **internal aggregate events** to the **stable public API** defined in the spec package.

**`ProductsExtensionPoint.res`** (in the plugin package):
```rescript
open ReventlessInfra.ExtensionPointMapping

module ExtensionPoint = CatalogSpec.ProductsExtensionPoint  // Reference spec via namespace

module ProductMapping = {
  module ExtensionPoint = ExtensionPoint
  module Aggregate = Product

  let mapIncomingCommand = (_id, _command, _meta) => []  // No inbound commands

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

Key points:
- **`module ExtensionPoint`** — references the spec from the spec package via its namespace
- **One module per source aggregate** — wrap each in a named module (e.g., `ProductMapping` inside the EP mapping file)
- **`mapIncomingCommand`** — translates extension point commands to aggregate commands (empty for read-only EPs)
- **`mapOutgoingEvent`** — translates aggregate events to extension point events. Use `Some(...)` when active, `None` when not needed
- **Fan-out** — a single aggregate event can produce multiple EP events (return an array)

**Fan-out example** (Order → multiple ItemOrdered events):
```rescript
let mapOutgoingEvent = Some((id, event, _meta, _queryEngine) =>
  switch event {
  | Placed({customerId, productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(productId, ItemOrdered({productId, orderId: id, customerId}))
    )
  | Cancelled({productIds}) =>
    productIds->Array.map(productId =>
      PublishEvent(productId, ItemOrderCancelled({productId, orderId: id}))
    )
  | _ => []
  }
)
```

---

### Extensions

An extension **subscribes to another plugin's extension point** and routes the incoming events to local aggregate commands.

**`OrdersExtension.res`** (Catalog subscribing to Ordering):
```rescript
open ReventlessInfra.ExtensionMapping

module ExtensionPoint = OrderingSpec.OrdersExtensionPoint  // Cross-plugin reference

module Mapping = {
  module ExtensionPoint = ExtensionPoint
  module Aggregate = ProductDemand       // Local aggregate to command

  open Aggregate
  open ExtensionPoint
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        PublishAggregateCommand(productId, Record({orderId: orderId})),
      ]
    | ItemOrderCancelled({productId, orderId}) => [
        PublishAggregateCommand(productId, Revoke({orderId: orderId})),
      ]
    }

  let mapOutgoingEvent = None
}
```

Pattern:
- **`module ExtensionPoint`** — the external EP spec, referenced through the spec package namespace
- **`module Aggregate`** — the local aggregate that will receive commands
- **`open Aggregate` + `open ExtensionPoint`** — allows unqualified command and event access in the mapping
- **`PublishAggregateCommand(id, command)`** — route to a specific aggregate instance

---

### Plugin Composition

The plugin's **composition root** is `src/Plugin.res` — auto-generated by `generate-plugin` (from `reventless-spec`) before each build. A developer creates files in the right folders; the next `npm run build` regenerates and compiles `Plugin.res` automatically.

#### Setting up the generator

Add `generate` and `prebuild` scripts to the plugin's `package.json`:

```json
{
  "scripts": {
    "generate": "generate-plugin src/",
    "prebuild": "npm run generate",
    "build": "rescript build"
  }
}
```

#### plugin.json (optional)

Place `src/plugin.json` to override defaults:

```json
{
  "name": "Catalog",
  "heartbeatInterval": 60,
  "exclude": ["Product/StateChangeSlice/Experimental.res"]
}
```

| Field | Default | Notes |
|-------|---------|-------|
| `name` | Derived from `package.json` name | Unscoped, hyphens/underscores → PascalCase. e.g. `online-shop-aggregates-catalog` → `OnlineShopAggregatesCatalog`. Use this field to keep it short: `"Catalog"`. |
| `heartbeatInterval` | `60` | Seconds |
| `exclude` | `[]` | File paths or glob patterns relative to `src/` — file stays in repo and compiles, just not wired into the plugin |

#### What the generator discovers

The generator walks `src/` and classifies `.res` files by their parent folder name. Chapter folders (e.g. `Product/`, `Category/`) are transparent — only the leaf folder name is matched.

| Folder name(s) | Component |
|---|---|
| `Aggregate[s]` | Aggregate — paired with `*Behavior.res` |
| `ReadModel[s]` | Read model — paired with `*Projections.res` |
| `Task[s]` | Task |
| `ExtensionPoint[s]` | Extension point mapping |
| `Extension[s]` | Extension mapping |
| `StateChange[s][Slice[s]]` | DCB StateChangeSlice |
| `StateView[s][Slice[s]]` | DCB StateViewSlice |
| `Automation[s][Slice[s]]` | DCB AutomationSlice |
| `InboundTranslation[s][Slice[s]]` | DCB InboundTranslationSlice |
| `OutboundTranslation[s][Slice[s]]` | DCB OutboundTranslationSlice |

Always excluded: `Plugin/`, `tests/`, `lib/`, `*Test.res`, `*Fixtures.res`.

#### Convention: Extension files expose `module Mapping`

Each file in `Extension/` must expose its mapping as an inner module named **`Mapping`** (not `DemandMapping`, `ProductMapping`, etc.):

```rescript
// OrdersExtension.res
open ReventlessInfra.ExtensionMapping

module Mapping = {
  module ExtensionPoint = OrderingSpec.OrdersExtensionPoint
  module Delegate = ProductDemand
  // ...
}
```

The generator references it as `OrdersExtension.Mapping`.

#### Generated output (aggregate catalog)

```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Aggregates
  module CategoryAggregate = Platform.Aggregate.Make(
    Category, CategoryBehavior, ReventlessInfra.NoEventMappings.Make(Category),
  )
  module ProductAggregate = Platform.Aggregate.Make(
    Product, ProductBehavior, ReventlessInfra.NoEventMappings.Make(Product),
  )
  module ProductDemandAggregate = Platform.Aggregate.Make(
    ProductDemand, ProductDemandBehavior, ReventlessInfra.NoEventMappings.Make(ProductDemand),
  )

  // ReadModels
  @reventless.projections
  module CategoriesProjectionsWrapper: Mappings with module Target := CategoriesReadModel = {
    let mappings: array<module(Mapping)> = [module(CategoriesProjections.CategoryMapping)]
  }
  module CategoriesReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoriesProjectionsWrapper)

  @reventless.projections
  module ProductDemandProjectionsWrapper: Mappings with module Target := ProductDemandReadModel = {
    let mappings: array<module(Mapping)> = [
      module(ProductDemandProjections.ProductMapping),
      module(ProductDemandProjections.ProductDemandMapping),
    ]
  }
  module ProductDemandReadModel = Platform.ReadModel.Make(ProductDemandReadModel, ProductDemandProjectionsWrapper)

  // ExtensionPoints
  module ProductsExtensionPoint = Platform.ExtensionPoint.Make(ProductsExtensionPointMapping)

  // Extensions
  module OrdersExtension = Platform.Extension.Make(OrdersExtension.Mapping)

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPoint)],
      ~extensions=[module(OrdersExtension)],
      ~aggregates=[module(CategoryAggregate), module(ProductAggregate), module(ProductDemandAggregate)],
      ~readModels=[module(CategoriesReadModel), module(ProductDemandReadModel), ...],
      ~tasks=[module(ImportProductsTask)],
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Catalog",
          ~aggregates=[module(CategoryAggregate), module(ProductAggregate), module(ProductDemandAggregate)],
          ~readModels=[module(CategoriesReadModel), module(ProductDemandReadModel), ...],
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
```

The generated file is **committed to git** — changes are visible in code review, and CI compiles it directly without re-running the generator.

**Notes on the generated code:**
- `@reventless.projections` wraps each projections module; the PPX injects `module M`, `module type Mapping`, and `let moduleUrl`
- `Platform.ExtensionPoint.Make` takes just the mapping module — no `Config` second argument
- Aggregates with a custom event-mappings file (e.g. `Order_EventMappings.res` under `src/EventMappings/`) are wired automatically: `Platform.Aggregate.Make(Order, OrderBehavior, Order_EventMappings)`. Event mappings let an aggregate receive events published by other aggregates (via EventTopic subscriptions) and route them to local commands. The default third argument, `ReventlessInfra.NoEventMappings.Make(Spec)`, is used when no such inbound routing is needed

---

## DCB Approach

In the **DCB** (Dynamic Consistency Boundary) approach all events for a bounded context share a single event log. Commands are handled by **StateChangeSlices** (write-side) using a minimal decision model built by filtering the shared log by entity tag. Queries are handled by **StateViewSlices** (read-side) that project the same log into a query database. Use this approach when a command's validity depends on multiple entity types or the consistency boundary varies per command.

The DCB example lives in `examples/online-shop-dcb/` and mirrors the same online-shop domain as the aggregate example.

### Key differences from the aggregate approach

| Aspect | Aggregates | DCB |
|--------|-----------|-----|
| Event storage | One event stream per aggregate instance | One shared event log per bounded context |
| Write-side | Behavior (`initialState`/`evolve`/`decide`) | StateChangeSlice (`initialState`/`evolve`/`decide`) |
| Read-side | ReadModel + Projection mappings | StateViewSlice (`project`) |
| Entity filtering | Implicit (stream per ID) | Explicit (`@s.matches(DcbTag.string)` on entity ID fields) |
| State model | Full aggregate state rebuilt from events | Minimal decision model — only what's needed to accept/reject |

---

### DCB Event Log

A DCB event log defines **all events** for a bounded context in a single type. Entity ID fields are tagged with `@s.matches(DcbTag.string)` so the runtime can filter events by entity.

**`CatalogEventLog.res`**:
```rescript
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
  | ProductPriceChanged({productId: @s.matches(DcbTag.string) string, price: float})
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryRenamed({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryArchived({categoryId: @s.matches(DcbTag.string) string})

let moduleUrl: string = %raw(`import.meta.url`)
```

Key points:
- **`@s.matches(DcbTag.string)`** — required on every entity ID field. In StateChangeSlice files the PPX auto-injects this on all `*Id: string`, `*Id: array<string>`, and `*Ids: array<string>` fields. For event log type definitions (outside slice folders), the annotation must be explicit
- **Both command AND event types** need the tag annotation on entity ID fields
- For cross-entity commands, use `array<@s.matches(DcbTag.string) string>` on array fields that reference other entities (see [Cross-Entity Queries](#cross-entity-queries-tagged-arrays) below)
- All entity types (Product, Category, etc.) share the same event log
- The event log file has no `name` or `Id` — it's just a type definition
- **`let moduleUrl`** — required. The framework uses this at deploy time to locate the event log module at runtime

---

### StateChangeSlice

A StateChangeSlice handles commands using a **state** (decision model) — a minimal projection of past events that captures only the information needed to accept or reject a command.

**`AddProduct.res`**:
```rescript
@@reventless.spec

open CatalogEventLog

module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | AddProduct({
      productId: string,
      name: string,
      description: string,
      price: float,
    })

@schema
type error = | ProductAlreadyExists

type state = {exists: bool}

let initialState = {exists: false}

let evolve = (state, event) =>
  switch event {
  | ProductAdded(_) => {exists: true}
  | _ => state
  }

let decide = (state, command) =>
  switch command {
  | AddProduct({productId, name, description, price}) =>
    if state.exists {
      Error(ProductAlreadyExists)
    } else {
      Ok([ProductAdded({productId, name, description, price})])
    }
  }
```

Because `AddProduct.res` is in a `StateChangeSlice/` folder, `@@reventless.spec` automatically applies DCB tag injection — no `@@reventless.dcbTags` annotation is needed. The PPX auto-injects `@s.matches(Reventless.DcbTag.string)` on all `*Id: string`, `*Id: array<string>`, and `*Ids: array<string>` fields in `@schema` types.

If a variant has multiple `*Id` fields and only one is the partition key, use the `@partitionTag` field annotation to disambiguate (see the [PPX guide](./reventless-ppx.md#partitiontag-notag-dcbtag--field-level-dcb-tag-control)).

**StateChangeSlice spec fields:**

| Field | Purpose |
|-------|---------|
| `module DcbEventLogSpec` | Links to the shared event log |
| `command` | Commands this slice handles (entity ID fields auto-tagged by PPX) |
| `error` | Domain error variants |
| `state` | Minimal state needed for command decisions |
| `initialState` | Starting value before any events |
| `evolve` | Fold events into state |
| `decide` | Accept or reject a command → `Ok(events)` or `Error(error)` |

**Contrast with aggregates:**
- Both approaches use the same naming: `initialState`/`evolve`/`decide`
- The state (decision model) is typically much smaller than full aggregate state (e.g., `{exists: bool}` vs the entire product record)
- The `evolve` function receives ALL events from the log (filtered by entity ID tag), so use `| _ => state` to skip irrelevant ones

#### Cross-Entity Queries (Tagged Arrays)

When a command references multiple entities (e.g., PlaceOrder with a list of product IDs), use a `*Id: array<string>` field (singular name). The PPX auto-injects `@s.matches(DcbTag.string)` on the element type:

```rescript
@schema
type command =
  | PlaceOrder({
      orderId: string,                  // auto-tagged: DcbTag.string
      customerId: string,               // NOT tagged (no *Id suffix query intent)
      productId: array<string>,         // auto-tagged on elements: DcbTag.string
    })
```

The runtime automatically detects tagged array fields via schema introspection and builds a multi-clause OR query — one clause per scalar tag and one clause per array element:

```
// For PlaceOrder({orderId: "ord-1", productId: ["prod-1", "prod-2"]}):
[
  {eventTypes: [...], tags: [{key: "orderId", value: "ord-1"}]},
  {eventTypes: [...], tags: [{key: "productId", value: "prod-1"}]},
  {eventTypes: [...], tags: [{key: "productId", value: "prod-2"}]},
]
```

This fetches Order events (by `orderId`) AND CatalogProduct events (by each `productId`) into the same decision model, enabling cross-entity validation at command time. No configuration is needed — the schema IS the configuration.

**Key rules for cross-entity commands:**
- Name the array field to match the tag key on the referenced events (e.g., command field `productId` matches the `productId` tag on `CatalogProductSynced` events)
- Commands with only scalar tagged fields produce single-clause AND queries (standard behavior, unchanged)
- The append condition automatically covers all queried entities for optimistic concurrency

See `examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/PlaceOrder.res` for a complete cross-entity example.

---

### StateViewSlice

A StateViewSlice projects events from the shared event log into a query-side read model. It replaces the ReadModel + Projection pattern from the aggregate approach.

**`ProductsView.res`**:
```rescript
open Reventless.Projection
open CatalogEventLog

let name = "ProductsView"

module DcbEventLogSpec = CatalogEventLog

@schema
type event = CatalogEventLog.event

@schema
type state = {productId: string, name: string, description: string, price: float}

let project = event =>
  switch event {
  | ProductAdded({productId, name, description, price}) => [
      Set(productId, {productId, name, description, price}),
    ]
  | ProductNameChanged({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductPriceChanged({productId, price}) => [Update(productId, state => {...state, price})]
  | _ => []
  }
```

**StateViewSlice spec fields:**

| Field | Purpose |
|-------|---------|
| `name` | Unique view name |
| `module DcbEventLogSpec` | Links to the shared event log |
| `event` | Event type (always `= DcbEventLogSpec.event`) |
| `state` | Read model record shape |
| `project` | Map events to `Set`/`Update`/`Ignore` operations |

The `project` function uses the same operations as aggregate projections (`Set`, `Update`, `Ignore`), but receives events directly from the shared log rather than through mapping modules.

---

### DCB Plugin Composition

The DCB plugin composition root is auto-generated from the folder structure, same as aggregates. It uses different builder functors and passes DCB slice arrays directly to `Plugin.make`.

**`Plugin.res`** (generated):
```rescript
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // ── StateChangeSlices (write-side) ─────────────────────────
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  // ... more slices ...

  // ── StateViewSlices (read-side) ────────────────────────────
  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)
  // ... more views ...

  // ── Extension Point (outbound) ──────────────────────────────
  module ProductsExtensionPoint = Platform.ExtensionPoint.Make(
    ProductsExtensionPointMapping,
  )

  // ── Extension (inbound from Ordering) ───────────────────────
  module OrdersExtension = Platform.Extension.Make(
    OrdersExtension.Mapping,
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPoint)],
      ~extensions=[module(OrdersExtension)],
      ~stateChangeSlices=[
        module(AddProductSlice),
        module(ChangeProductNameSlice),
        // ... all write slices ...
      ],
      ~stateViewSlices=[
        module(ProductsViewSlice),
        // ... all view slices ...
      ],
    )
}
```

**Key differences from aggregate plugin composition:**
- **`Platform.StateChangeSlice.Make`** instead of aggregate + behavior
- **`Platform.StateViewSlice.Make`** instead of read model + projection mappings
- **DCB slice arrays** (`~stateChangeSlices`, `~stateViewSlices`, etc.) passed directly to `Plugin.make` — empty arrays can be omitted. Use `Platform.StateChangeSlice.MakeAsync(Spec)` instead of `Make(Spec)` for high-contention slices; `MakeAsync` slices use a FIFO queue and return `CommandPending`, while `Make` slices use the sync channel and return `CommandAccepted` / `CommandRejected`. Both go in the same `~stateChangeSlices` array.

---

### DCB Extension Point / Extension Adapter Pattern

Extension points and extensions in DCB work the same as in aggregates, but require a **shim module** to expose the DCB event log as an `Aggregate.Spec`. This is because the EP/Extension mapping infrastructure expects aggregate-shaped modules.

**Extension point mapping** (`ProductsExtensionPointMapping.res`):
```rescript
open Reventless
open ReventlessInfra.ExtensionPointMapping

module ExtensionPoint = CatalogSpec.ProductsExtensionPoint

// DCB adapter: exposes CatalogEventLog as Aggregate.Spec
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
      PublishEvent(productId, ExtensionPoint.ProductBecameAvailable({productId, name, price})),
    ]
  | CatalogEventLog.ProductPriceChanged({productId, price}) => [
      PublishEvent(productId, ExtensionPoint.ProductPriceChanged({productId, price})),
    ]
  | _ => []
  }
)
```

**Extension mapping** (`OrdersExtension.res`):
```rescript
open ReventlessInfra.ExtensionMapping

module Mapping = {
  module ExtensionPoint = OrderingSpec.OrdersExtensionPoint
  module Delegate = RecordProductDemand   // DCB slice spec used as delegate

  open ExtensionPoint
  open RecordProductDemand
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        PublishAggregateCommand(productId, RecordDemand({productId, orderId})),
      ]
    | ItemOrderCancelled({productId, orderId}) => [
        PublishAggregateCommand(productId, RevokeDemand({productId, orderId})),
      ]
    }

  let mapOutgoingEvent = None
}
```

The extension file exports `module Mapping` — the generator references it as `OrdersExtension.Mapping`.

---

### DCB Directory Layout

```
online-shop-dcb/
├── catalog-spec/              # Spec package (extension point types)
│   ├── package.json
│   ├── rescript.json
│   └── src/
│       └── ProductsExtensionPoint.res
├── ordering-spec/             # Spec package
│   └── ...
├── catalog/                   # Plugin package
│   ├── package.json
│   ├── rescript.json
│   └── src/
│       ├── Product/
│       │   ├── StateChangeSlice/
│       │   │   ├── AddProduct.res
│       │   │   ├── ChangeProductName.res
│       │   │   └── ...
│       │   └── StateViewSlice/
│       │       ├── ProductsView.res
│       │       └── ProductDemandView.res
│       ├── Category/
│       │   ├── StateChangeSlice/
│       │   └── StateViewSlice/
│       ├── ExtensionPoint/
│       │   └── ProductsExtensionPointMapping.res
│       ├── Extension/
│       │   └── OrdersExtension.res
│       ├── Plugin/
│       │   └── CatalogEventLog.res    # Shared event log type
│       └── Plugin.res                  # Auto-generated composition root
├── ordering/                  # Plugin package
│   └── ...
└── online-shop-dcb/           # Platform package
    ├── package.json
    ├── rescript.json
    └── src/
        └── Main.res
```

**Compared to aggregates:**
- `Aggregate/` → `<Entity>/StateChangeSlice/` (one file per command, not per aggregate)
- `ReadModel/` → `<Entity>/StateViewSlice/` (view replaces read model + projection)
- `Plugin/CatalogEventLog.res` — new: the shared event log type definition
- No separate `Behavior` files (logic is inline in each slice)

---

### DCB Package Structure

Spec packages are **identical** between the aggregate and DCB approaches — they contain the same extension point type definitions. This means both examples can share the same EP specs.

**Package naming convention:**

```
@reventlessdev/online-shop-dcb-catalog-spec    # Spec package
@reventlessdev/online-shop-dcb-catalog          # Plugin package
@reventlessdev/online-shop-dcb                  # Platform package
```

**Namespace strategy:**

Both examples use the same namespace conventions (`CatalogSpec`, `CatalogPlugin`, etc.). They build independently — each example group has its own build root with `package-specs` in its platform package's `rescript.json`.

---

### DCB Platform Package

The platform `Main.res` is identical to the aggregate version:

```rescript
module Platform = ReventlessInMemory.Platform.Make()

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
)
```

Plugin modules are referenced as `<Namespace>.Plugin.Make(Platform)` — `Plugin` is the generated module name within the package namespace.

---

## Hybrid Composition

The aggregate and DCB approaches can be mixed within a single plugin. `Plugin.make` accepts both `~aggregates` and DCB slice arrays as optional parameters — entities that are self-contained use aggregates, while entities that share consistency boundaries use a DCB event log.

### When to Use Each Approach

| Use **aggregates** when | Use **DCB** when |
|------------------------|------------------|
| Entity is self-contained — commands only need the entity's own history | A command's validity depends on multiple entity types |
| Entity has a clear lifecycle state machine | The consistency boundary varies per command |
| No cross-entity consistency requirements at command time | Tag-based filtering provides a natural scope for events |
| Entity is high-volume and would create noise in a shared log | Complex cross-entity invariants exist within the plugin |

**Key constraint:** Entities that need cross-entity decisions **must** share the same DCB event log. An aggregate cannot participate in a DCB decision model, and a DCB slice cannot replay aggregate events.

### Hybrid Plugin Composition

A hybrid plugin passes both `~aggregates` and DCB slice arrays to `Plugin.make`:

```rescript
// CatalogPlugin.res — hybrid: Category aggregate + Product/Demand DCB
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // --- Aggregate-based: Category (independent entity) ---
  module CategoryAggregate = Platform.Aggregate.Make(Category, CategoryBehavior)
  module CategoriesReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoriesProjections)

  // --- DCB-based: Product + ProductDemand (cross-entity consistency) ---
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  // ... more slices

  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~aggregates=[module(CategoryAggregate)],        // Aggregate components
      ~readModels=[module(CategoriesReadModel)],      // Aggregate read models
      ~stateChangeSlices=[                            // DCB slices
        module(AddProductSlice),
        module(ChangeProductNameSlice),
      ],
      ~stateViewSlices=[
        module(ProductsViewSlice),
        module(ProductDemandViewSlice),
      ],
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Catalog",
          ~aggregates=[module(CategoryAggregate)],
          ~readModels=[module(CategoriesReadModel)],
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
```

Both contribute to the unified GraphQL schema automatically — aggregate mutations/queries and DCB mutations/queries appear side by side.

### ReadModel Sourcing from DCB EventTopic

A traditional `ReadModel` can subscribe to a DCB event log's EventTopic alongside aggregate EventTopics. The DCB EventTopic is added to the `allEventTopics` dictionary under the key `<pluginName> ++ "DcbEventLog"` (e.g., `"CatalogDcbEventLog"`).

To create a ReadModel that projects events from both an aggregate and the DCB log, define two `Mapping` modules:

```rescript
module CategoryMapping = {
  let sourceName = "Category"  // aggregate name
  @schema type sourceEvent = Category.event
  type targetState = myState
  let project = (msg) => switch msg.event {
  | Added({name}) => Create(msg.id, {categoryName: name})
  | _ => Ignore
  }
}

module CatalogDcbMapping = {
  let sourceName = "CatalogDcbEventLog"  // <pluginName> ++ "DcbEventLog"
  @schema type sourceEvent = CatalogEventLog.event
  type targetState = myState
  let project = (msg) => switch msg.event {
  | ProductAdded({productId, name}) => Create(productId, {productName: name})
  | _ => Ignore
  }
}

module MyReadModel = {
  // ...
  let mappings = [module(CategoryMapping), module(CatalogDcbMapping)]
}
```

### Extension Points in Hybrid Plugins

Extension point mappings work identically for aggregate and DCB events. The existing DCB extension point adapter pattern (shim module) is the same whether the plugin is pure DCB or hybrid:

```rescript
// ProductsExtensionPointMapping.res — maps DCB events to extension point
module DcbEventLogSpec = CatalogEventLog

let extensionPointSpec = module(CatalogSpec.ProductsExtensionPoint)

let mapEvent = event =>
  switch event {
  | CatalogEventLog.ProductAdded({productId, name, price}) =>
    Some(CatalogSpec.ProductsExtensionPoint.ProductAdded({productId, name, price}))
  | _ => None
  }
```

Other plugins see the extension point API and never know whether the source is an aggregate or DCB slice.

### Directory Layout

```
catalog/
├── src/
│   ├── Category/
│   │   ├── Aggregate/
│   │   │   ├── Category.res          # Aggregate spec
│   │   │   └── CategoryBehavior.res  # Aggregate behavior
│   │   └── ReadModel/
│   │       ├── CategoriesReadModel.res
│   │       └── CategoriesProjections.res
│   ├── Product/
│   │   ├── StateChangeSlice/
│   │   │   ├── AddProduct.res
│   │   │   └── ChangeProductName.res
│   │   └── StateViewSlice/
│   │       └── ProductsView.res
│   ├── Plugin/
│   │   └── CatalogEventLog.res       # DCB events (excludes Category)
│   ├── Plugin.res                     # Auto-generated composition root
│   └── ExtensionPoint/
│       └── ProductsExtensionPointMapping.res
└── tests/
    ├── Category/
    │   └── CategoryBehaviorTest.res   # Aggregate behavior (pure unit test)
    ├── Product/
    │   └── ProductDecisionTest.res    # DCB decision logic (pure unit test)
    └── E2E/
        └── CatalogE2ETest.res         # Integration test
```

### Reference Example

See `examples/online-shop-hybrid/` for a complete working example with two hybrid plugins (Catalog and Ordering), demonstrating:

- Category and Customer as aggregates (independent entities)
- Product/Demand and Order/CatalogProduct as DCB slices (cross-entity consistency)
- Extension points bridging between plugins regardless of modeling approach
- Behavior tests (aggregates), decision tests (DCB), and E2E tests

---

## Platform Package

The platform package wires plugins together and starts the application.

**`Main.res`**:
```rescript
module Platform = ReventlessInMemory.Platform.Make()

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
)
```

Plugin modules are referenced as `<Namespace>.Plugin.Make(Platform)`: the package namespace (e.g. `CatalogPlugin`) followed by the generated `Plugin` module.

### Configuration

**`rescript.json`** for the platform package:
```json
{
  "name": "@reventlessdev/online-shop-aggregates",
  "namespace": true,
  "sources": [{"dir": "src", "subdirs": true}],
  "bs-dependencies": [
    "sury",
    "@reventlessdev/rescript-pulumi-pulumi",
    "@reventlessdev/reventless-spec",
    "@reventlessdev/reventless-infra",
    "@reventlessdev/reventless-in-memory",
    "@reventlessdev/online-shop-aggregates-catalog-spec",
    "@reventlessdev/online-shop-aggregates-ordering-spec",
    "@reventlessdev/online-shop-aggregates-catalog",
    "@reventlessdev/online-shop-aggregates-ordering"
  ],
  "bsc-flags": ["-open", "RescriptCore"]
}
```

The platform depends on **all** spec and plugin packages.

---

## Configuration Reference

### Package naming convention

```
@reventlessdev/online-shop-aggregates-catalog-spec    # Spec package
@reventlessdev/online-shop-aggregates-catalog          # Plugin package
@reventlessdev/online-shop-aggregates                  # Platform package
```

Pattern: `<org>/<platform-name>-<plugin-name>[-spec]`

### Namespace strategy

| Package type | Namespace | Example |
|-------------|-----------|---------|
| Spec | `<Plugin>Spec` | `CatalogSpec` |
| Plugin | `<Plugin>Plugin` | `CatalogPlugin` |
| Platform | `true` (auto) | — |

**Warning:** Never use a bare plugin name as a namespace (e.g., `"Ordering"`) — it can shadow modules from `RescriptCore` (e.g., `Ordering.t` for comparisons). Always use a suffixed name like `OrderingPlugin`.

### Dependency order

In both `package.json` and `rescript.json`, order dependencies as:

1. Third-party packages (`sury`, etc.)
2. ReScript bindings (`rescript-pulumi-pulumi`, etc.)
3. Framework packages (`reventless-spec`, `reventless-infra`, `reventless-in-memory`)
4. Example/platform packages (`online-shop-aggregates-*`)

### package.json dependency placement

| Package | Section | Why |
|---------|---------|-----|
| `sury` | `dependencies` | Runtime — compiled JS imports from sury |
| `sury-ppx` | `devDependencies` | Build-time only — PPX code generator |
| `rescript` | `devDependencies` + `peerDependencies` | Compiler |
| `@glennsl/rescript-jest` | `devDependencies` | Test-only |

### rescript.json dependency placement

| Package | Section | Why |
|---------|---------|-----|
| Framework & plugin packages | `bs-dependencies` | Used in production source |
| `@glennsl/rescript-jest` | `dev-dependencies` | Used only in test sources |

### Split API mode

By default, the in-memory platform uses split API mode — core administrative schema (plugin management, clone) and plugin business domain schema are served on separate ports. Use `MakeWithConfig` with `splitApi = false` to serve them from a single endpoint instead.

**Port assignments (default — split mode):**

| Service | Port |
|---------|------|
| GraphQL (plugin) | 4000 |
| GraphQL (core) | 4001 |
| MCP (plugin) | 3001 |
| MCP (core) | 3002 |

Use `MakeWithConfig` to disable split mode:

```rescript
module Platform = ReventlessInMemory.Platform.MakeWithConfig({
  let silent = false
  let splitApi = false
})
```

In unified mode (`splitApi=false`), all schema is served from a single GraphQL endpoint (port 4000) and a single MCP endpoint (port 3001).

**When to use split mode:**

- **Security boundary** — restrict administrative operations (activate/deactivate plugins, clone) to internal networks or specific auth groups, while exposing business domain APIs to external clients.
- **AI agent clarity** — an agent working with business data sees only domain-relevant tools and queries, not administrative operations like `Admin_Plugin_Activate`.
- **Independent scaling** — admin traffic is low-frequency; plugin business traffic is high-frequency. Separate endpoints allow independent rate limiting.

**What changes in split mode:**

- Admin types/queries/mutations (`Admin_Plugin`, `Admin_Plugins`, `Admin_Plugin_Activate`, `Admin_Plugin_Deactivate`, `Admin_Clone`) register into a dedicated `GraphQL_ServerInstance` on port 4001 instead of the shared singleton.
- Admin MCP tools/resources register into a dedicated `MCP_ServerInstance` on port 3002.
- Plugin schema continues to register into the `GraphQL_Server` / `MCP_Server` singletons on the default ports.
- No changes to plugin code, resolver modules, or hooks.

**AWS split mode** is the default — `Platform.Make()` uses split API automatically:

```rescript
module Platform = ReventlessAws.Platform.Make()
```

In split mode, `makePlatform` creates a dedicated admin AppSync API. Access the admin API outputs for stack exports:

```rescript
// After makePlatform:
switch ReventlessAws.Platform.getSplitApiOutputs() {
| Some({coreApi}) =>
  let coreApiId = coreApi->Pulumi.Output.apply(api => api.id)
  let coreApiUrl = coreApi->Pulumi.Output.apply(api => api.uris)
    ->Pulumi.Output.apply(u => u.graphQL)
  // Export as Pulumi stack outputs from your entry point
| None => () // unified mode — no separate admin API
}
```

---

## Cross-Plugin Communication

The extension point / extension pattern enables plugins to communicate without direct dependencies.

### Data flow

```
Plugin A (Publisher)                    Plugin B (Subscriber)
─────────────────────                  ──────────────────────
Aggregate events                       Extension
    │                                      │
    ▼                                      ▼
ExtensionPoint mapping                 Extension mapping
(aggregate event → EP event)           (EP event → aggregate command)
    │                                      │
    ▼                                      ▼
   EP Spec (shared types)              Local aggregate
    └────────────────────────────────────┘
         via spec package
```

### Example: Ordering notifies Catalog of new orders

1. **Ordering** publishes `OrdersExtensionPoint` events when an order is placed
2. **Catalog** subscribes via `OrdersExtension` and routes to `ProductDemand` aggregate

**Spec** (`ordering-spec/src/OrdersExtensionPoint.res`):
```rescript
type event =
  | ItemOrdered({productId: string, orderId: string, customerId: string})
  | ItemOrderCancelled({productId: string, orderId: string})
```

**Publisher** (`ordering/src/ExtensionPoint/OrdersExtensionPoint.res`):
```rescript
// Maps Order.Placed → ItemOrdered (one per product)
| Placed({customerId, productIds}) =>
  productIds->Array.map(productId =>
    PublishEvent(productId, ItemOrdered({productId, orderId: id, customerId}))
  )
```

**Subscriber** (`catalog/src/Extension/OrdersExtension.res`):
```rescript
// Maps ItemOrdered → ProductDemand.Record command
| ItemOrdered({productId, orderId}) => [
    PublishAggregateCommand(productId, Record({orderId: orderId})),
  ]
```

### Extension-driven aggregates

When a plugin needs to store state from external events, create a dedicated aggregate. In the Catalog plugin, `ProductDemand` exists solely to record order demand driven by Ordering's events. In the Ordering plugin, `CatalogProduct` shadows Catalog's product data.

These aggregates:
- Have no user-facing commands (only extension-driven)
- Are fully idempotent (safe to replay)
- Enable the plugin to query external data locally via read models

---

## AutoUI

AutoUI publishes a runtime UI manifest from plugin metadata so the platform's UI shell can mount the plugin's React components without any hardcoded imports. The plugin packages its UI as a Module-Federation remote bundle; the platform asks each connected plugin for the bundle URL and the list of components to mount.

### How it's enabled

When a plugin has at least one aggregate or read model, the `generate-plugin` code generator emits an optional `~uiBundleUrl=?` parameter on the plugin's `make` and wires the conditional manifest:

```rescript
let make = (~uiBundleUrl=?) =>
  Platform.Plugin.make(
    ~name="Catalog",
    ~heartbeatInterval=60,
    ~aggregates=[module(CategoryAggregate)],
    ~readModels=[module(CategoriesReadModel)],
    // ... other params ...
    ~uiFragments=?uiBundleUrl->Option.map(url =>
      Platform.Plugin.makeAutoUIManifest(
        ~remoteEntryUrl=url,
        ~name="Catalog",
        ~aggregates=[module(CategoryAggregate)],
        ~readModels=[module(CategoriesReadModel)],
        ~readModelPositions=["platform-summary"],
        ~aggregatePositions=["resource-detail"],
      )
    ),
  )
```

When `uiBundleUrl` is `None` (the default), `~uiFragments` is `None` and the plugin connects without a UI manifest — the platform shell shows nothing for it. When set, `makeAutoUIManifest` builds a `uiFragmentManifest` with the bundle's remote-entry URL and the list of components to mount in each shell slot. Plugins with neither aggregates nor read models get a plain `make = ()` with no UI parameter.

### Supplying `uiBundleUrl` per deployment

The bundle URL is deployment configuration, not plugin code. Both deploy paths read it from the same env var: `<PLUGIN>_UI_BUNDLE_URL` (PascalCase plugin name → SCREAMING_SNAKE_CASE — e.g., `Catalog` → `CATALOG_UI_BUNDLE_URL`, `OnlineShop` → `ONLINE_SHOP_UI_BUNDLE_URL`).

**In-memory (`platform-in-memory/src/Main.res`)** — the composition root reads env explicitly and forwards:

```rescript
@val external processEnv: dict<string> = "process.env"

module CatalogMaker = {
  let make = () =>
    Catalog.make(~uiBundleUrl=?processEnv->Dict.get("CATALOG_UI_BUNDLE_URL"))
}
```

**AWS (`catalog-aws/src/Plugin.res`)** — the generator emits the env-var read directly. The deployer calls `make()` (no args) per the `PluginMaker.make: unit => component` contract:

```rescript
@val external uiBundleUrl: option<string> = "process.env.CATALOG_UI_BUNDLE_URL"

module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  module Composition = CatalogPlugin.Plugin.Make(Platform)
  let make = () => Composition.make(~uiBundleUrl?)
}
```

For local dev: `CATALOG_UI_BUNDLE_URL=http://localhost:5001 pnpm dev`. For AWS: set the env var on the Pulumi stack to a CloudFront URL pointing at the uploaded bundle.

### Component → AutoUI role

| Component | AutoUI role |
|---|---|
| `Aggregate` | Commands — write-side; state is internal, not queryable |
| `ReadModel` | List / detail view — aggregate-style queryable projection |
| `StateViewSlice` | List / detail view — DCB equivalent of ReadModel |
| `StateChangeSlice` | Commands — independent; not linked to any specific view |

Aggregates and StateChangeSlices provide command forms; ReadModels and StateViewSlices provide the queryable views those forms act on. The UI resolves linkage between them at render time — there is no automatic coupling at the manifest level.

### Accessing the manifest at runtime

When a plugin connects with `Some(manifest)`, the platform's admin handler emits a `UIFragmentRegistered` event and writes the manifest into the `Plugin` admin read model. The shell observes the read model and the `Platform_UIFragmentRegistered/Updated/Deregistered` subscription to mount and unmount components.

### No manual steps

You never call `makeAutoUIManifest` by hand. The generator regenerates `Plugin.res` on every `pnpm run build`; new aggregates and read models appear in the manifest automatically. Toggle UI on per deployment by setting or unsetting the env var.

---

## Conventions & Pitfalls

### Naming

- **Aggregate names** — singular nouns: `Product`, `Order`, `Customer`
- **Read model names** — plural nouns: `Products`, `Orders`, `Customers`
- **Commands** — imperative: `Add`, `UpdateName`, `Ship`, `Cancel`
- **Events** — past tense: `Added`, `NameUpdated`, `Shipped`, `Cancelled`
- **Extension point names** — dotted: `"Catalog.Products"`, `"Ordering.Orders"`

### Behavior patterns

- **Idempotency** — return `Ok([])` when a command produces no change
- **`decide`** — a single function handles all commands; use pattern matching on state to distinguish "not yet created" from "existing"
- **Error variants** — define explicit domain errors, not generic strings; return `Error(variant)` from `decide`
- **`initialState`** — defines the starting state before any events (represents "not yet created")

### Module opens

- Use `open Product` (the aggregate spec) inside behaviors and projections for unqualified event/command access
- Use `open ExtensionPoint` in EP mappings and extensions for unqualified EP event access
- Use `module Aggregate = ProductDemand` + `open Aggregate` in extensions for unqualified command access

### Common mistakes

- **Circular plugin dependencies** — always use spec packages for cross-plugin references
- **Namespace shadowing** — avoid short namespace names that conflict with RescriptCore modules
- **Missing `@schema`** — every command, event, error, state, and directive type needs it
- **Payload-less events** (e.g., `| Shipped`) — these serialize as bare JSON strings rather than objects. This is fully supported by `splitMessage`/`combineMessage`, so you can freely use payload-less variants when no payload is needed
- **Stale build cache** — after renaming or moving files, run `npx rescript clean` then rebuild

---
