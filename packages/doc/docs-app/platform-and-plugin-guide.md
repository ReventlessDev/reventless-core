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
   - [The Shared Event Log (Implicit)](#the-shared-event-log-implicit)
   - [StateChangeSlice](#statechangeslice)
   - [StateViewSlice](#stateviewslice)
   - [StateViewSliceStream](#stateviewslicestream)
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
    - [Annotations that shape Auto UI](#annotations-that-shape-auto-ui)
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
| Write-side | `Behavior` (`initialState`/`evolve`/`decide`) | `StateChangeSlice` spec + `_Behavior` (`initialState`/`evolve`/`decide`) |
| Read-side | `ReadModel` + `Projection` mappings | `StateViewSlice` spec + `_Projection` (`project`) |
| Entity filtering | Implicit (stream scoped to ID) | Implicit inside `*Slice/` folders — `@s.matches(DcbTag.string)` is auto-injected on `*Id` fields |
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
    │   ├── Product_Behavior.res      # Aggregate behavior (state machine)
    │   ├── Category.res
    │   ├── Category_Behavior.res
    │   ├── ProductDemand.res        # Extension-driven aggregate
    │   └── ProductDemand_Behavior.res
    ├── ReadModel/
    │   ├── Products.res    # Read model spec (state shape)
    │   ├── Products_Projections.res  # Projection mappings
    │   ├── Categories.res
    │   ├── Categories_Projections.res
    │   ├── ProductDemands.res
    │   └── ProductDemands_Projections.res
    ├── ExtensionPoint/
    │   └── Products_ExtensionPointMapping.res  # Maps aggregate events → EP events
    ├── Extension/
    │   └── Orders_Extension.res                # Maps EP events → aggregate commands
    ├── Task/
    │   └── ImportProducts.res                  # Background task (S3 → commands)
    └── Plugin.res                              # Auto-generated composition root
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

For high-contention aggregates where FIFO ordering is more important than synchronous results, opt in to the async channel by adding `@@reventless.async` at the top of the spec file:

```rescript title="Inventory.res"
@@reventless.spec
@@reventless.async

@schema
type command = ...
```

The plugin generator then emits `Platform.Aggregate.MakeAsync(Inventory, InventoryBehavior, ...)` instead of `Make` — no edits needed to `Plugin.res` (it's regenerated by `prebuild`).

| Channel | Spec attribute | Mutation result | Use when |
|---------|----------------|-----------------|----------|
| `SQS_Sync` (default) | none | `CommandAccepted` \| `CommandRejected` | User-facing CRUD, payment commands |
| `SQS_Async` | `@@reventless.async` | `CommandPending` | High-contention writes, internal automation |

Async aggregates land in a separate `AllAggregatesAsyncCmdHandler` Lambda; sync aggregates stay on the default `AllAggregatesCmdHandler` Lambda. Each Lambda is only provisioned when at least one aggregate of that flavor exists — sync-only setups pay no extra Lambda cost.

---

### Behaviors

A behavior implements the aggregate state machine: state evolution from events, and command decisions.

**`Product_Behavior.res`**:
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

**`Products.res`**:
```rescript
@@reventless.spec

@schema
type state = {
  productId: string,
  name: string,
  description: string,
  price: float,
}
```

The PPX derives `let name = "Products"` from the filename and, because the file lives under a `ReadModel/` folder and declares `@schema type state` without a `let config`, also auto-injects `open Reventless.ReadModel; let config = config(); let subIdConfig = None`.

- **`state`** — the record stored per entity in the query database
- **`config`** — default configuration (pagination, etc.)
- **`subIdConfig`** — for sub-entity read models (`None` for top-level)

---

### Projections

Projections map aggregate events to read model state changes.

**`Products_Projections.res`** (single-source):
```rescript
@@reventless.mappings

module ProductMapping = Mapping.Make(
  Product,    // Source aggregate
  Products,   // Target read model
  {
    open Product     // Open aggregate for unqualified event access
    let project = ({event, id, _}) =>
      switch event {
      | Added({name, description, price}) =>
        Set(id, {Products.productId: id, name, description, price})
      | NameUpdated({name}) => Update(id, state => {...state, name})
      | DescriptionUpdated({description}) => Update(id, state => {...state, description})
      | PriceUpdated({price}) => Update(id, state => {...state, price})
      }
  },
)

let mappings: array<module(Mapping)> = [module(ProductMapping)]
```

The `@@reventless.mappings` PPX infers the domain from the folder (`ReadModel/` → `Reventless.Projection`), injects `open Reventless.Projection` (and `open Reventless.Message` for the `event` record destructuring), and wires up `module type Mapping` so the user only writes the per-source `Mapping.Make` modules and the `let mappings` array.

**Projection operations:**

| Operation | Purpose |
|-----------|---------|
| `Set(id, state)` | Create or replace the entire record |
| `Update(id, state => newState)` | Partially update an existing record |
| `Ignore` | Skip this event |

**Multi-source projections** — when a read model combines events from multiple aggregates, define one mapping per source:

**`ProductDemands_Projections.res`**:
```rescript
@@reventless.mappings

module ProductMapping = Mapping.Make(
  Product,
  ProductDemands,
  {
    open Product
    let project = ({event, id, _}) =>
      switch event {
      | Added({name}) =>
        Set(id, {ProductDemands.productId: id, name, orderCount: 0})
      | _ => Ignore
      }
  },
)

module ProductDemandMapping = Mapping.Make(
  ProductDemand,
  ProductDemands,
  {
    open ProductDemand
    let project = ({event, id, _}) =>
      switch event {
      | Recorded(_) =>
        Update(id, (state: ProductDemands.state) => {
          ...state, orderCount: state.orderCount + 1
        })
      | Revoked(_) =>
        Update(id, (state: ProductDemands.state) => {
          ...state, orderCount: max(0, state.orderCount - 1)
        })
      }
  },
)

let mappings: array<module(Mapping)> = [module(ProductMapping), module(ProductDemandMapping)]
```

When the target read model type is ambiguous in the `Update` callback, annotate the `state` parameter: `(state: ProductDemands.state)`.

---

### ReadModelStream

`ReadModelStream` is a variant of `ReadModel` whose query view also pushes
**live updates** to subscribed browsers (AppSync Events "Source B" — the AutoUI
list/detail refresh-without-reload behavior). Use it for read models backing a
UI list or detail that users keep open and expect to stay fresh.

**Spec and projection files are identical to `ReadModel`** — same `@@reventless.spec`
state, same `@@reventless.mappings` projection, same DSL. The only difference is
the folder name and the platform factory the generator picks.

**Folder convention:**

| Folder | Generator emits | Builder used (AWS) |
|--------|------------------|--------------------|
| `ReadModel/` | `Platform.ReadModel.Make(Spec, Projections)` | `ReadModel_Builder_Single` (plain DynamoDB QueryDb) |
| `ReadModelStream/` | `Platform.ReadModelStream.Make(Spec, Projections)` | `ReadModel_Builder_Single_Stream` (DynamoDB QueryDb **with stream enabled**) |

**What the stream variant adds (AWS):**

- The QueryDb table is provisioned with a **DynamoDB Stream**.
- The read model registers itself in `QueryDbStorage_DynamoDbStream.streamRegistry` on `make`.
- The platform's `subscriptionInfraHook` wires a `StateTopic_AppSync` Lambda per
  registered read model that forwards stream changes into the AppSync **Events
  API**, so any browser viewing the list/detail receives change descriptors.

**What it does not change:**

- In the local platform, `ReadModelStream` is an alias for `ReadModel` (no DynamoDB streams to enable).
- The shape of `Spec` / `Projections` files, the GraphQL query field, resolvers,
  authorization, or the AutoUI manifest — only the live-update wiring differs.

**Choosing between the two:**

- Plain `ReadModel/` — query-only / on-demand views (reports, admin lookups,
  detail pages opened fresh). Cheaper: no DynamoDB Stream, no extra Lambda.
- `ReadModelStream/` — lists/details users watch live, or that change from other
  actors / automations / background tasks. Costs one DynamoDB Stream + one
  StateTopic Lambda per read model.

Switching is a folder rename — the spec/projection code stays the same. The same
choice for DCB read-side views is `StateViewSlice/` vs `StateViewSliceStream/`
(see [StateViewSliceStream](#stateviewslicestream)). See
[AppSync Events & Live Updates](/infrastructure/appsync-events-live-updates) for the full
publisher/subscriber contract.

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

**`Orders_Extension.res`** (Catalog subscribing to Ordering):
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
| `ReadModel[s]` | Read model — paired with `*_Projections.res` |
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
// Orders_Extension.res
open ReventlessInfra.ExtensionMapping

module Mapping = {
  module ExtensionPoint = OrderingSpec.OrdersExtensionPoint
  module Delegate = ProductDemand
  // ...
}
```

The generator references it as `Orders_Extension.Mapping`.

#### Generated output (aggregate catalog)

```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Aggregates
  module CategoryAggregate = Platform.Aggregate.Make(
    Category, Category_Behavior, ReventlessInfra.NoEventMappings.Make(Category),
  )
  module ProductAggregate = Platform.Aggregate.Make(
    Product, Product_Behavior, ReventlessInfra.NoEventMappings.Make(Product),
  )
  module ProductDemandAggregate = Platform.Aggregate.Make(
    ProductDemand, ProductDemand_Behavior, ReventlessInfra.NoEventMappings.Make(ProductDemand),
  )

  // ReadModels — the projections file declares `let mappings` via
  // `@@reventless.mappings`, so the generator references it directly.
  // The wrapper LHS appends `ReadModel` so it doesn't shadow the bare-named spec.
  module CategoriesReadModel = Platform.ReadModel.Make(Categories, Categories_Projections)
  module ProductDemandsReadModel = Platform.ReadModel.Make(ProductDemands, ProductDemands_Projections)

  // ExtensionPoints
  module Products_ExtensionPoint = Platform.ExtensionPoint.Make(Products_ExtensionPointMapping)

  // Extensions
  module Orders_Extension = Platform.Extension.Make(Orders_Extension.Mapping)

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(Products_ExtensionPoint)],
      ~extensions=[module(Orders_Extension)],
      ~aggregates=[module(CategoryAggregate), module(ProductAggregate), module(ProductDemandAggregate)],
      ~readModels=[module(CategoriesReadModel), module(ProductDemandsReadModel), ...],
      ~tasks=[module(ImportProductsTask)],
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Catalog",
          ~aggregates=[module(CategoryAggregate), module(ProductAggregate), module(ProductDemandAggregate)],
          ~readModels=[module(CategoriesReadModel), module(ProductDemandsReadModel), ...],
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
```

The generated file is **committed to git** — changes are visible in code review, and CI compiles it directly without re-running the generator.

**Notes on the generated code:**
- The wrapper LHS for ReadModels appends `ReadModel` (e.g. `module CategoriesReadModel = Platform.ReadModel.Make(Categories, Categories_Projections)`) so it doesn't shadow the bare-named spec module (`Categories`).
- `Platform.ExtensionPoint.Make` takes just the mapping module — no `Config` second argument.
- Aggregates with a custom event-mappings file (e.g. `Order_Mappings.res`) are wired automatically: `Platform.Aggregate.Make(Order, Order_Behavior, Order_Mappings)`. Event mappings let an aggregate receive events published by other aggregates (via EventTopic subscriptions) and route them to local commands. The default third argument, `ReventlessInfra.NoEventMappings.Make(Spec)`, is used when no such inbound routing is needed.

---

## DCB Approach

In the **DCB** (Dynamic Consistency Boundary) approach all events for a bounded context share a single event log. Commands are handled by **StateChangeSlices** (write-side) using a minimal decision model built by filtering the shared log by entity tag. Queries are handled by **StateViewSlices** (read-side) that project the same log into a query database. Use this approach when a command's validity depends on multiple entity types or the consistency boundary varies per command.

A DCB plugin's slices live under per-entity chapter folders (`Product/StateChangeSlice/`, `Product/StateViewSliceStream/`, etc.). There is **no shared event-log file**: each slice declares the typed subset of events it reads (`consumedEvent`) and the events it appends (`event`), and the runtime stitches them into one log per bounded context. The hybrid example (`examples/online-shop-hybrid/`) demonstrates DCB slices alongside aggregates in the same plugin.

### Key differences from the aggregate approach

| Aspect | Aggregates | DCB |
|--------|-----------|-----|
| Event storage | One event stream per aggregate instance | One shared event log per bounded context |
| Write-side | Behavior (`initialState`/`evolve`/`decide`) | StateChangeSlice spec + `_Behavior` (`initialState`/`evolve`/`decide`) |
| Read-side | ReadModel + Projection mappings | StateViewSlice spec + `_Projection` (`project`) |
| Entity filtering | Implicit (stream per ID) | Implicit inside `*Slice/` folders — `@s.matches(DcbTag.string)` is auto-injected on `*Id` fields |
| State model | Full aggregate state rebuilt from events | Minimal decision model — only what's needed to accept/reject |

---

### The Shared Event Log (Implicit)

In DCB all events for a bounded context share a single event log — but there is **no shared event-log file** to write. Each slice declares only the slices of that log it needs:

- A `@schema type event` on a `StateChangeSlice` spec — the events that slice **appends** to the log.
- A `@schema type consumedEvent` on a `StateChangeSlice` / `StateViewSlice` spec — the typed subset of the log it **reads** (used to build the decision model or projection). Variants from sibling slices that the consumer doesn't enumerate decode as parse errors and fall through harmlessly.

The runtime stitches every slice's `event` and `consumedEvent` declarations into one per-plugin log and tags entries by entity ID.

**Tagging is automatic inside `*Slice/` folders.** The `@@reventless.spec` PPX auto-injects `@s.matches(Reventless.DcbTag.string)` on all `*Id: string`, `*Id: array<string>`, and `*Ids: array<string>` fields in `@schema` types — on both `command`/`event` and `consumedEvent`. You never write `@s.matches` by hand in a slice file. Use `@partitionTag` (and `@noDcbTag`, `@dcbTag`) only to disambiguate when a variant has more than one `*Id` field (see [StateChangeSlice](#statechangeslice) and the [PPX guide](reventless-ppx.md)).

---

### StateChangeSlice

A StateChangeSlice handles commands using a **state** (decision model) — a minimal projection of past events that captures only the information needed to accept or reject a command. Like aggregates, it is **split into two files**: a spec (`<Name>.res`) declaring the types, and a behavior (`<Name>_Behavior.res`) holding the state machine.

**`AddProduct.res`** (spec — types only):
```rescript
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded

@schema
type command =
  | AddProduct({
      productId: string,
      name: string,
      description: string,
      price: float,
    })

@schema
type error = ProductAlreadyExists

@schema
type event =
  | ProductAdded({
      productId: string,
      name: string,
      description: string,
      price: float,
    })
```

**`AddProduct_Behavior.res`** (behavior — state machine):
```rescript
@@reventless.behavior

type state = {exists: bool}

let initialState = {exists: false}

let evolve = (_state, event) =>
  switch event {
  | ProductAdded => {exists: true}
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

Because `AddProduct.res` is in a `StateChangeSlice/` folder, `@@reventless.spec` automatically applies DCB tag injection — no `@@reventless.dcbTags` annotation and no manual `@s.matches` are needed. The PPX auto-injects `@s.matches(Reventless.DcbTag.string)` on all `*Id: string`, `*Id: array<string>`, and `*Ids: array<string>` fields in `@schema` types (`command`, `event`, and `consumedEvent`).

If a variant has multiple `*Id` fields and only one is the partition key, use the `@partitionTag` field annotation to disambiguate (mirror `PlaceOrder.res`, which tags `@partitionTag orderId` so its `productIds` array fans out without colliding with the order tag — see the [PPX guide](reventless-ppx.md#partitiontag-nodcbtag-dcbtag--field-level-dcb-tag-control)).

The `@@reventless.behavior` PPX opens the spec module so event/command variants resolve unqualified in `evolve`/`decide`. It derives the spec module from the filename (`AddProduct_Behavior.res` → `AddProduct`); use `@@reventless.behavior(SpecName)` to override.

**StateChangeSlice spec fields (`<Name>.res`):**

| Field | Purpose |
|-------|---------|
| `consumedEvent` | The typed subset of the shared log this slice reads (drives the decision model). Entity ID fields auto-tagged by PPX |
| `command` | Commands this slice handles (entity ID fields auto-tagged by PPX) |
| `error` | Domain error variants |
| `event` | The events this slice appends to the shared log (entity ID fields auto-tagged) |

**Behavior definitions (`<Name>_Behavior.res`):**

| Definition | Purpose |
|-------|---------|
| `state` | Minimal state needed for command decisions |
| `initialState` | Starting value before any events |
| `evolve` | Fold consumed events into state |
| `decide` | Accept or reject a command → `Ok(events)` or `Error(error)` |

**Contrast with aggregates:**
- Both approaches split spec + behavior and use the same naming: `initialState`/`evolve`/`decide`
- The state (decision model) is typically much smaller than full aggregate state (e.g., `{exists: bool}` vs the entire product record)
- `evolve` receives only the slice's `consumedEvent` variants (the log filtered by entity ID tag), so the match is exhaustive over that small set rather than the full log

#### Cross-Entity Queries (Tagged Arrays)

When a command references multiple entities (e.g., PlaceOrder with a list of product IDs), use an `*Ids: array<string>` field. The PPX auto-injects `@s.matches(DcbTag.string)` on the element type and auto-singularises the trailing `s`, so each element is stored under tag key `productId` — sharing the key with single-value `productId: string` producers. Use `@partitionTag` to mark which scalar `*Id` field anchors the slice's own entity when several `*Id` fields coexist:

```rescript
@schema
type consumedEvent =
  | OrderPlaced({orderId: string})
  | CatalogProductSynced({productId: string})

@schema
type command =
  PlaceOrder({@partitionTag orderId: string, customerId: string, productIds: array<string>})

@schema
type event =
  OrderPlaced({@partitionTag orderId: string, customerId: string, productIds: array<string>})
```

The runtime automatically detects tagged array fields via schema introspection and builds a multi-clause OR query — one clause per scalar tag and one clause per array element:

```
// For PlaceOrder({orderId: "ord-1", productIds: ["prod-1", "prod-2"]}):
[
  {eventTypes: [...], tags: [{key: "orderId", value: "ord-1"}]},
  {eventTypes: [...], tags: [{key: "productId", value: "prod-1"}]},
  {eventTypes: [...], tags: [{key: "productId", value: "prod-2"}]},
]
```

This fetches Order events (by `orderId`) AND CatalogProduct events (by each `productId`) into the same decision model, enabling cross-entity validation at command time. No configuration is needed — the schema IS the configuration.

**Key rules for cross-entity commands:**
- Name the array field so its singularised key matches the tag key on the referenced events (e.g., command field `productIds` → tag key `productId`, matching the `productId` tag on `CatalogProductSynced` events)
- Use `@partitionTag` on the slice's own `*Id` field so events from sibling entities sharing a tag don't leak into the decision model
- Commands with only scalar tagged fields produce single-clause AND queries (standard behavior, unchanged)
- The append condition automatically covers all queried entities for optimistic concurrency

See `examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/PlaceOrder.res` for a complete cross-entity example.

---

### StateViewSlice

A StateViewSlice projects events from the shared event log into a query-side read model. It replaces the ReadModel + Projection pattern from the aggregate approach.

**`Products.res`** (spec):
```rescript
@@reventless.spec

@schema
type state = {productId: string, name: string, description: string, price: float}

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string, description: string, price: float})
  | ProductNameChanged({productId: string, name: string})
  | ProductPriceChanged({productId: string, price: float})
```

**`Products_Projection.res`** (body):
```rescript
@@reventless.projection

let project = event =>
  switch event {
  | ProductAdded({productId, name, description, price}) => [
      Set(productId, {productId, name, description, price}),
    ]
  | ProductNameChanged({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductPriceChanged({productId, price}) => [Update(productId, state => {...state, price})]
  }
```

**StateViewSlice file split:**

| File | Purpose |
|---|---|
| `<Name>.res` | Spec — declares `@schema type state` and `@schema type consumedEvent` (the typed subset of the shared DCB log this view cares about). The PPX auto-injects `let name`, `module Id`, `let config`, `let subIdConfig`, `open Reventless.Projection`. |
| `<Name>_Projection.res` | Body — the `let project = event => ...` function returning `Set`/`Update`/`UpdateWithDefault`/`Delete`/`Ignore` operations. The PPX auto-opens the spec module so event variants resolve unqualified. |

The `project` function uses the same operations as aggregate projections, but receives events directly from the shared DCB log rather than through per-source mapping modules.

---

### StateViewSliceStream

`StateViewSliceStream` is a variant of `StateViewSlice` whose query view is **also exposed as a live subscription source**. Use it when clients need to subscribe to state changes (push), not just query the current value (pull).

**Spec and projection are identical to `StateViewSlice`** — same `Spec`, same `Projection`, same `project` function, same DSL. The only thing that differs is the folder name and the platform factory the generator picks.

**Folder convention:**

| Folder | Generator emits | Builder used (AWS) |
|--------|------------------|--------------------|
| `StateViewSlice/` | `Platform.StateViewSlice.Make(Spec, Projection)` | `StateViewSlice_Builder` (plain DynamoDB QueryDb) |
| `StateViewSliceStream/` | `Platform.StateViewSliceStream.Make(Spec, Projection)` | `StateViewSlice_Builder_Stream` (DynamoDB QueryDb **with stream enabled**) |

**What the stream variant adds (AWS):**

- The QueryDb table is provisioned with a **DynamoDB Stream**.
- The slice registers itself in `QueryDbStorage_DynamoDbStream.streamRegistry` on `make`.
- The platform wires a `StateTopic_AppSync` Lambda per registered slice that forwards stream changes into the AppSync **Events API**, enabling GraphQL subscriptions on the projected state.

**What it does not change:**

- In the local platform, `StateViewSliceStream` is an alias for `StateViewSlice` (no DynamoDB streams to enable).
- The shape of `Spec` / `Projection` files — you can move a slice between the two folders without editing its contents.

**Example layout:**

```
src/Product/StateViewSliceStream/
├── Products.res                  // Spec — identical shape to a StateViewSlice spec
├── Products_Projection.res
├── ProductDemand.res
└── ProductDemand_Projection.res
```

**Choosing between the two:**

- Plain `StateViewSlice/` — query-only views (typical read models). Cheaper: no DynamoDB Stream, no extra Lambda.
- `StateViewSliceStream/` — views clients live-subscribe to via GraphQL subscriptions on the AppSync Events API.

Switching is a folder rename — the spec/projection code stays the same.

---

### DCB Plugin Composition

The DCB plugin composition root is auto-generated from the folder structure, same as aggregates. It uses different builder functors and passes DCB slice arrays directly to `Plugin.make`.

**`Plugin.res`** (generated):
```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices — spec + behavior (two args)
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName, ChangeProductName_Behavior)
  // ... more slices ...

  // StateViewSliceStreams — spec + projection (two args)
  module ProductsStreamSlice = Platform.StateViewSliceStream.Make(Products, Products_Projection)
  // ... more views ...

  // ExtensionPoints
  module Products_ExtensionPoint = Platform.ExtensionPoint.Make(Products_ExtensionPointMapping)

  // Extensions
  module Orders_Extension = Platform.Extension.Make(Orders_Extension.Mapping)

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(Products_ExtensionPoint)],
      ~extensions=[module(Orders_Extension)],
      ~stateChangeSlices=[
        module(AddProductSlice),
        module(ChangeProductNameSlice),
        // ... all write slices ...
      ],
      ~stateViewSlices=[
        module(ProductsStreamSlice),
        // ... all view slices ...
      ],
    )
}
```

**Key differences from aggregate plugin composition:**
- **`Platform.StateChangeSlice.Make(Spec, Spec_Behavior)`** instead of aggregate + behavior
- **`Platform.StateViewSlice.Make(Spec, Spec_Projection)`** (or `StateViewSliceStream.Make` for the live-update variant) instead of read model + projection mappings
- **DCB slice arrays** (`~stateChangeSlices`, `~stateViewSlices`, etc.) passed directly to `Plugin.make` — empty arrays can be omitted. For high-contention slices, add `@@reventless.async` at the top of the slice spec file and the plugin generator will emit `Platform.StateChangeSlice.MakeAsync(Spec, Spec_Behavior)` instead of `Make`; async slices use a FIFO queue and return `CommandPending`, while sync slices use the standard channel and return `CommandAccepted` / `CommandRejected`. Both go in the same `~stateChangeSlices` array, and the async slices share a separate `<Plugin>DcbAsyncCmdHandler` Lambda only provisioned when at least one slice opts in (sync slices go to the per-plugin `<Plugin>DcbCmdHandler` Lambda).

---

### DCB Extension Point / Extension Adapter Pattern

Extension points and extensions in DCB work the same as in aggregates. To map DCB events to the public API, the EP mapping declares a small `module Delegate` whose `name` equals `<pluginName>DcbEventLog` (the key under which `Plugin_Builder` registers the plugin's DCB EventTopic) and a `@schema type event` listing just the variants the extension point cares about.

**Extension point mapping** (`Products_ExtensionPointMapping.res`):
```rescript
// Maps internal Catalog events to the stable Products_ExtensionPoint public API.
@@reventless.spec

module ExtensionPoint = CatalogSpec.Products_ExtensionPoint

// DCB adapter: the event type used for outgoing event mapping.
// `name` MUST equal `<pluginName>DcbEventLog`.
module Delegate = {
  let name = "CatalogDcbEventLog"
  @schema
  type event =
    | ProductAdded({productId: string, name: string, description: string, price: float})
    | ProductPriceChanged({productId: string, price: float})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.ProductAdded({productId, name, price}) => [
      PublishEvent(
        productId,
        CatalogSpec.Products_ExtensionPoint.ProductBecameAvailable({productId, name, price}),
      ),
    ]
  | Delegate.ProductPriceChanged({productId, price}) => [
      PublishEvent(productId, CatalogSpec.Products_ExtensionPoint.ProductPriceChanged({productId, price})),
    ]
  }
)
```

The `@@reventless.spec` PPX (on a file whose stem ends `_ExtensionPointMapping`) opens `ReventlessInfra.ExtensionPointMapping` — bringing `PublishEvent`, `PublishCommand`, `Call`, etc. into scope — and auto-transforms the `Delegate` module (injects `module Id`, a `unit` command/error, `let moduleUrl`).

**Extension mapping** (`Orders_Extension.res`):
```rescript
// Catalog's extension subscribing to Ordering's Orders_ExtensionPoint.
@@reventless.extension

module Mapping = {
  module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint
  module Delegate = RecordProductDemand   // DCB slice spec used as delegate

  open ExtensionPoint
  open RecordProductDemand
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        PublishStateChangeSliceCommand(RecordDemand({productId, orderId})),
      ]
    | ItemOrderCancelled({productId, orderId}) => [
        PublishStateChangeSliceCommand(RevokeDemand({productId, orderId})),
      ]
    }

  let mapOutgoingEvent = None
}
```

When the `Delegate` is a StateChangeSlice, use `PublishStateChangeSliceCommand(command)` (no id argument) — the framework derives the FIFO grouping id from the command's `@partitionTag` (or `@compositePartitionTag`) field. Use `PublishAggregateCommand(id, command)` only when the `Delegate` is an Aggregate.

The extension file exports `module Mapping` — the generator references it as `Orders_Extension.Mapping`.

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
│       │   │   ├── AddProduct.res            # Slice spec (types)
│       │   │   ├── AddProduct_Behavior.res   # Slice behavior (state machine)
│       │   │   ├── ChangeProductName.res
│       │   │   ├── ChangeProductName_Behavior.res
│       │   │   └── ...
│       │   └── StateViewSlice/
│       │       ├── Products.res              # View spec (state + consumedEvent)
│       │       ├── Products_Projection.res   # View projection
│       │       ├── ProductDemand.res
│       │       └── ProductDemand_Projection.res
│       ├── Category/
│       │   ├── StateChangeSlice/
│       │   └── StateViewSlice/
│       ├── ExtensionPoint/
│       │   └── Products_ExtensionPointMapping.res
│       ├── Extension/
│       │   └── Orders_Extension.res
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
- `Aggregate/` → `<Entity>/StateChangeSlice/` (one slice per command, not per aggregate)
- `ReadModel/` → `<Entity>/StateViewSlice/` (view replaces read model + projection)
- No shared event-log file — each slice declares its own `consumedEvent` (what it reads) and `event` (what it appends)
- Slices are still split spec + behavior: `<Name>.res` (`@@reventless.spec`) + `<Name>_Behavior.res` (`@@reventless.behavior`), exactly like aggregates

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
module Platform = ReventlessLocal.Platform.Make()

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
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
// Hybrid Catalog: Category aggregate + Product/Demand DCB slices
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // --- Aggregate-based: Category (independent entity) ---
  // The generated form always passes the event-mappings module as the third
  // arg — `NoEventMappings.Make(Category)` when there is no inbound routing.
  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    Category_Behavior,
    ReventlessInfra.NoEventMappings.Make(Category),
  )
  module CategoriesReadModel = Platform.ReadModel.Make(Categories, Categories_Projections)

  // --- DCB-based: Product + ProductDemand (cross-entity consistency) ---
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName, ChangeProductName_Behavior)
  // ... more slices

  module ProductsStreamSlice = Platform.StateViewSliceStream.Make(Products, Products_Projection)
  module ProductDemandStreamSlice = Platform.StateViewSliceStream.Make(ProductDemand, ProductDemand_Projection)

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
        module(ProductsStreamSlice),
        module(ProductDemandStreamSlice),
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

A traditional `ReadModel` can be fed by both an aggregate and the plugin's DCB log in the same multi-source `*_Projections.res` file. The DCB EventTopic is registered under the key `<pluginName> ++ "DcbEventLog"` (e.g., `"CatalogDcbEventLog"`), which is also the `meta.service` value DcbEventLog stamps on every published event — the two must match for events to route into the projection.

A DCB-sourced mapping declares an inner module whose `let name` equals `<pluginName>DcbEventLog` and a `@schema type event` listing the variants it cares about. The `@@reventless.mappings` PPX auto-tags the source as a DCB source (injects `module Id = Reventless.Id.String` and dcbTags on `*Id` fields). The aggregate source resolves to its `Spec.name`. Each source is wired with `Mapping.Make(Source, Target, { ... })`, and the file ends with `let mappings: array<module(Mapping)>`:

```rescript
@@reventless.mappings

// DCB source — `name` MUST equal `<pluginName>DcbEventLog`.
module CatalogDcbSource = {
  let name = "CatalogDcbEventLog"

  @schema
  type event =
    | ProductAdded({productId: string, name: string, description: string, price: float})
    | ProductRenamed({productId: string, name: string})
}

// Source 1 — Category Aggregate
module CategoryActivityMapping = Mapping.Make(
  Category,
  CatalogActivity,
  {
    open Category
    let project = ({event, id, _}) =>
      switch event {
      | Added({name}) =>
        Set(id, {CatalogActivity.name: name, kind: Category, lastChange: (Added: CatalogActivity.change)})
      | Renamed({name}) =>
        Update(id, state => {...state, name, lastChange: (Renamed: CatalogActivity.change)})
      | Archived =>
        Update(id, state => {...state, lastChange: (Archived: CatalogActivity.change)})
      }
  },
)

// Source 2 — Catalog DCB EventLog
module ProductActivityMapping = Mapping.Make(
  CatalogDcbSource,
  CatalogActivity,
  {
    open CatalogDcbSource
    let project = ({event, _}) =>
      switch event {
      | ProductAdded({productId, name}) =>
        Set(productId, {CatalogActivity.name: name, kind: Product, lastChange: Added})
      | ProductRenamed({productId, name}) =>
        Update(productId, state => {...state, name, lastChange: Renamed})
      }
  },
)

let mappings: array<module(Mapping)> = [module(CategoryActivityMapping), module(ProductActivityMapping)]
```

See `examples/online-shop-hybrid/catalog/src/CatalogActivity/ReadModel/CatalogActivity_Projections.res` for the complete mixed-source example.

### Extension Points in Hybrid Plugins

Extension point mappings work identically for aggregate and DCB events. The DCB extension point adapter pattern (the `module Delegate` whose `name` is `<pluginName>DcbEventLog`) is the same whether the plugin is pure DCB or hybrid:

```rescript
// Products_ExtensionPointMapping.res — maps DCB events to extension point
@@reventless.spec

module ExtensionPoint = CatalogSpec.Products_ExtensionPoint

module Delegate = {
  let name = "CatalogDcbEventLog"
  @schema
  type event =
    | ProductAdded({productId: string, name: string, description: string, price: float})
    | ProductPriceChanged({productId: string, price: float})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.ProductAdded({productId, name, price}) => [
      PublishEvent(
        productId,
        CatalogSpec.Products_ExtensionPoint.ProductBecameAvailable({productId, name, price}),
      ),
    ]
  | Delegate.ProductPriceChanged({productId, price}) => [
      PublishEvent(productId, CatalogSpec.Products_ExtensionPoint.ProductPriceChanged({productId, price})),
    ]
  }
)
```

Other plugins see the extension point API and never know whether the source is an aggregate or DCB slice.

### Directory Layout

```
catalog/
├── src/
│   ├── Category/
│   │   ├── Aggregate/
│   │   │   ├── Category.res           # Aggregate spec
│   │   │   └── Category_Behavior.res  # Aggregate behavior
│   │   └── ReadModel/
│   │       ├── Categories.res
│   │       └── Categories_Projections.res
│   ├── Product/
│   │   ├── StateChangeSlice/
│   │   │   ├── AddProduct.res             # Slice spec (consumedEvent/command/error/event)
│   │   │   ├── AddProduct_Behavior.res    # Slice behavior (state/initialState/evolve/decide)
│   │   │   ├── ChangeProductName.res
│   │   │   └── ChangeProductName_Behavior.res
│   │   └── StateViewSliceStream/
│   │       ├── Products.res               # View spec (state + consumedEvent)
│   │       └── Products_Projection.res    # View projection
│   ├── CatalogActivity/
│   │   └── ReadModel/
│   │       ├── CatalogActivity.res        # Mixed-source: Aggregate + DCB log
│   │       └── CatalogActivity_Projections.res
│   ├── ExtensionPoint/
│   │   └── Products_ExtensionPointMapping.res
│   ├── Extension/
│   │   └── Orders_Extension.res
│   └── Plugin.res                     # Auto-generated composition root
└── tests/
    └── ... (mirror src/ 1:1 — each component has a `<Name>_GWT.res`)
```

There is no shared event-log file: Product DCB events live entirely in the Product slices' `consumedEvent` / `event` declarations. Test files mirror the `src/` layout one-to-one so the PPX can infer each test's kind from its folder path.

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
module Platform = ReventlessLocal.Platform.Make()

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
    "@reventlessdev/reventless-local",
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
3. Framework packages (`reventless-spec`, `reventless-infra`, `reventless-local`)
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

By default, the local platform uses split API mode — core administrative schema (plugin management, clone) and plugin business domain schema are served on separate ports. Use `MakeWithConfig` with `splitApi = false` to serve them from a single endpoint instead.

**Port assignments (default — split mode):**

| Service | Port |
|---------|------|
| GraphQL (plugin) | 4000 |
| GraphQL (core) | 4001 |
| MCP (plugin) | 3001 |
| MCP (core) | 3002 |

Use `MakeWithConfig` to disable split mode:

```rescript
module Platform = ReventlessLocal.Platform.MakeWithConfig({
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
2. **Catalog** subscribes via `Orders_Extension` and routes to `ProductDemand` aggregate

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

**Subscriber** (`catalog/src/Extension/Orders_Extension.res`):
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

**Local (`platform-local/src/Main.res`)** — the composition root reads env explicitly and forwards:

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

### Annotations that shape Auto UI

A handful of PPX annotations on aggregate / read-model / state-view spec files steer how AutoUI renders. None of them require any UI-side wiring — the generator threads them through `Platform_UIDefinitions` and the host shell's AutoUI consumes them directly. See [the PPX guide](reventless-ppx.md) for per-annotation detail.

| Annotation | Placed on | What AutoUI does with it |
|---|---|---|
| `@displayName` | One or more `string` fields on a `@schema type state` | Picks the row label for list views and search results. Falls back to a non-`id` string field, then to `"id"`. (No canonical entry in the PPX guide yet.) |
| [`@id`](reventless-ppx.md#id-compositeid--partition-key-derivation) | A `string` field on a `@schema type state` | Marks the entity primary key. Used by the auto-generated query and by AutoUI's row-id wiring on per-row command forms. |
| [`@subId`](reventless-ppx.md#subid-compositesubid--sort-key-derivation) | A `string` field on a `@schema type state` | Adds a sort-key dimension to the entity's query field, so list views can drill into a specific sort key. |
| [`@status`](reventless-ppx.md#status--mark-the-lifecycle-status-field) | One field on a `@schema type state` | Names the lifecycle status field. AutoUI compares this field per row against each command's `@allowedStates` to decide whether to show the command. Falls back to a field literally named `"status"` if absent. |
| [`@allowedStates([…])`](reventless-ppx.md#allowedstates--per-variant-command-state-guard) | A single command variant on a `@schema type command` | Hides the command on rows whose `@status` field value isn't in the set. `[]` is "never show"; absent is "always show" (back-compat). |
| [`@dcbTag`](reventless-ppx.md#partitiontag-nodcbtag-dcbtag--field-level-dcb-tag-control) and family | Field-level inside command / event variants | Drives DCB tag inference. Affects which arg becomes `id: ID!` on the auto-generated GraphQL mutation. |
| [`@noApi`](reventless-ppx.md#noapi--exclude-commands-from-graphqlmcp-exposure) | Whole `@schema type command` or single variants | Excludes the command from the GraphQL surface entirely — AutoUI never sees it, so it never renders a button for it. |

A typical entity flow:

```rescript
@@reventless.spec

@schema
type status = Placed | Shipped | Cancelled

@schema
type state = {
  @id orderId: string,
  @displayName customerId: string,    // list-view label
  @status status: status,             // gates per-row commands
}

@schema
type command =
  | Place({customerId: string, productIds: array<string>})
  | @allowedStates([Orders.Placed]) Ship
  | @allowedStates([Orders.Placed]) Cancel
  | @noApi InternalRefund({reason: string})  // hidden entirely
```

After build, AutoUI's Orders list view labels rows by `customerId`, and the per-row `…` menu shows `Ship` and `Cancel` only on `Placed` rows. `InternalRefund` is invisible to the UI.

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
