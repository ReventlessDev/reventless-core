# Platform & Plugin Guide

This guide walks through building platforms with plugins using Reventless. It covers both the **aggregate** and **DCB** (Dynamic Consistency Boundary) approaches, using the **online-shop** examples (`examples/online-shop-aggregates/`, `examples/online-shop-dcb/`).

---

## Table of Contents

1. [Overview](#overview)
2. [Package Structure](#package-structure)
3. [Spec Packages](#spec-packages)
4. [Plugin Packages](#plugin-packages)
   - [Aggregates](#aggregates)
   - [Behaviors](#behaviors)
   - [Read Models](#read-models)
   - [Projections](#projections)
   - [Extension Points](#extension-points)
   - [Extensions](#extensions)
   - [Plugin Composition](#plugin-composition)
5. [Platform Package](#platform-package)
6. [Configuration Reference](#configuration-reference)
   - [Split API Mode](#split-api-mode)
7. [Cross-Plugin Communication](#cross-plugin-communication)
8. [Conventions & Pitfalls](#conventions--pitfalls)
9. [DCB Approach](#dcb-approach)
   - [DCB Event Log](#dcb-event-log)
   - [StateChangeSlice](#statechangeslice)
   - [StateViewSlice](#stateviewslice)
   - [DCB Plugin Composition](#dcb-plugin-composition)
   - [DCB Extension Point / Extension Adapter Pattern](#dcb-extension-point--extension-adapter-pattern)
   - [DCB Directory Layout](#dcb-directory-layout)
   - [DCB Package Structure](#dcb-package-structure)
   - [DCB Platform Package](#dcb-platform-package)

---

## Overview

A Reventless **platform** is a deployable application composed of one or more **plugins**. Each plugin owns a bounded context with its own aggregates, read models, extension points, and extensions.

```
Platform
├── Plugin A
│   ├── Aggregates        (write-side: commands → events)
│   ├── Read Models       (query-side: events → projections)
│   ├── Extension Points  (outbound: publish events to other plugins)
│   └── Extensions        (inbound: subscribe to events from other plugins)
└── Plugin B
    └── ...
```

Plugins never depend on each other directly. Cross-plugin communication flows through **extension points** — stable public APIs that decouple the publisher from all subscribers.

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
│       └── CatalogPlugin.res
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

Each extension point spec defines:

| Field | Purpose |
|-------|---------|
| `name` | Unique identifier for the extension point consisting of Plugin and ExtensionPoint name|
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
  "sources": [{"dir": "src", "subdirs": true}],
  "bs-dependencies": ["sury"],
  "bsc-flags": ["-open", "RescriptCore"]
}
```

Key points:
- **Minimal dependencies** — only `sury` and `reventless-spec`
- **Explicit namespace** (e.g., `CatalogSpec`) — other packages reference types as `CatalogSpec.ProductsExtensionPoint`
- **No `sury-ppx` in rescript.json** — it goes in `package.json` devDependencies and the ppx is configured in `bsc-flags` (inherited from project settings)

---

## Plugin Packages

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
    └── CatalogPlugin.res               # Composition root
```

---

### Aggregates

An aggregate spec defines the command/event vocabulary and error types.

**`Product.res`** (aggregate spec):
```rescript
open Reventless
module Id = Id.String

let name = "Product"

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

Conventions:
- **`module Id = Id.String`** — aggregate identity type (use `Id.String` for string IDs)
- **`let name`** — unique aggregate name within the plugin
- Commands are **imperative** (`Add`, `UpdateName`), events are **past tense** (`Added`, `NameUpdated`)
- All types use `@schema` for serialization
- Error variants for domain validation failures

---

### Behaviors

A behavior implements the aggregate state machine: initialization, event application, and command handling.

**`ProductBehavior.res`**:
```rescript
open Reventless
open Product          // Open the aggregate spec for unqualified access

module Spec = Product // Required: links behavior to its aggregate spec

@schema
type state = {name: string, description: string, price: float}

let resolverConfig = {
  Behavior.commandSchema,
  fields: [],
}

// Initialize state from the first event (aggregate creation)
let init = event =>
  switch event {
  | Added({name, description, price}) => {name, description, price}
  | NameUpdated(_) | DescriptionUpdated(_) | PriceUpdated(_) =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

// Apply subsequent events to existing state
let apply = (state, event) =>
  switch event {
  | Added({name, description, price}) => {name, description, price}
  | NameUpdated({name}) => {...state, name}
  | DescriptionUpdated({description}) => {...state, description}
  | PriceUpdated({price}) => {...state, price}
  }

// Handle commands when aggregate does NOT exist yet
let create = (command, _context, errorHandler) =>
  switch command {
  | Add({name, description, price}) => [Added({name, description, price})]
  | UpdateName(_) | UpdateDescription(_) | UpdatePrice(_) =>
    errorHandler(ProductNotFound, command, _context)
  }

// Handle commands when aggregate already exists
let execute = (state, command, context, errorHandler) =>
  switch command {
  | Add(_) => errorHandler(ProductAlreadyExists, command, context)
  | UpdateName({name}) if name == state.name => []         // idempotent
  | UpdateName({name}) => [NameUpdated({name: name})]
  | UpdateDescription({description}) if description == state.description => []
  | UpdateDescription({description}) => [DescriptionUpdated({description: description})]
  | UpdatePrice({price}) if price == state.price => []
  | UpdatePrice({price}) => [PriceUpdated({price: price})]
  }
```

**Four handler functions:**

| Function | When called | Returns |
|----------|-------------|---------|
| `init` | First event replayed (aggregate creation) | Initial state |
| `apply` | Each subsequent event during replay | Updated state |
| `create` | Command arrives, no aggregate exists | Events to emit |
| `execute` | Command arrives, aggregate exists | Events to emit |

**Idempotency pattern:** Return `[]` (empty event list) when a command would produce no change. This makes retries safe.

**Error handling:** Call `errorHandler(error, command, context)` for domain violations. The framework routes errors to the caller.

---

### Read Models

A read model defines the query-side state shape.

**`ProductsReadModel.res`**:
```rescript
open Reventless
module Id = Id.String

@schema
type state = {
  productId: string,
  name: string,
  description: string,
  price: float,
}

let name = "Products"

open Reventless.ReadModel
let config = config()
let subIdConfig = None
```

- **`state`** — the record stored per entity in the query database
- **`name`** — unique read model name
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
    let map = ({event, id, _}) =>
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
    let map = ({event, id, _}) =>
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
    let map = ({event, id, _}) =>
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
- **One module per source aggregate** — wrap each in a named module (e.g., `ProductMapping`)
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

module DemandMapping = {
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

The plugin file is the **composition root** — it wires all components together using the platform's builder functors.

**`CatalogPlugin.res`**:
```rescript
open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {

  // ── Aggregates ──────────────────────────────────────────────
  module ProductAggregate = Platform.Aggregate.Make(
    Product,
    ProductBehavior,
    ReventlessInfra.NoEventMappings.Make(Product),
  )

  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    ReventlessInfra.NoEventMappings.Make(Category),
  )

  module ProductDemandAggregate = Platform.Aggregate.Make(
    ProductDemand,
    ProductDemandBehavior,
    ReventlessInfra.NoEventMappings.Make(ProductDemand),
  )

  // ── Read Model Projections ──────────────────────────────────
  module ProductProjections: Mappings with module Target := ProductsReadModel = {
    module M = Mappings.Make(ProductsReadModel)
    module type Mapping = M.Mapping
    let mappings: array<module(Mapping)> = [
      module(ProductsProjections.ProductMapping),
    ]
  }
  module ProductReadModel = Platform.ReadModel.Make(ProductsReadModel, ProductProjections)

  module CategoryProjections: Mappings with module Target := CategoriesReadModel = {
    module M = Mappings.Make(CategoriesReadModel)
    module type Mapping = M.Mapping
    let mappings: array<module(Mapping)> = [
      module(CategoriesProjections.CategoryMapping),
    ]
  }
  module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryProjections)

  // Multi-source read model: two mapping modules
  module DemandProjections: Mappings with module Target := ProductDemandReadModel = {
    module M = Mappings.Make(ProductDemandReadModel)
    module type Mapping = M.Mapping
    let mappings: array<module(Mapping)> = [
      module(ProductDemandProjections.ProductMapping),
      module(ProductDemandProjections.ProductDemandMapping),
    ]
  }
  module ProductDemandReadModelMaker = Platform.ReadModel.Make(
    ProductDemandReadModel,
    DemandProjections,
  )

  // ── Extension Point (outbound) ──────────────────────────────
  module ProductsEPProductMapping = ReventlessInfra.ExtensionPointMapping.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtensionPoint.ProductMapping,
  )
  module ProductsEPMappings = {
    module Spec = CatalogSpec.ProductsExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T
      with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(ProductsEPProductMapping)]
  }
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsEPMappings,
  )

  // ── Extension (inbound from Ordering) ───────────────────────
  module OrdersDemandMapping = ReventlessInfra.ExtensionMapping.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtension.DemandMapping,
  )
  module OrdersExtensionMappings: ReventlessInfra.ExtensionMapping.Mappings
    with module Spec := OrderingSpec.OrdersExtensionPoint = {
    module type Mapping = ReventlessInfra.ExtensionMapping.T
      with module ExtensionPoint := OrderingSpec.OrdersExtensionPoint
    let name = "CatalogDemand"
    let mappings: array<module(Mapping)> = [module(OrdersDemandMapping)]
  }
  module OrdersExtensionMaker = Platform.Extension.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtensionMappings,
  )

  // ── Self-assembly ───────────────────────────────────────────
  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~aggregates=[
        module(ProductAggregate),
        module(CategoryAggregate),
        module(ProductDemandAggregate),
      ],
      ~readModels=[
        module(ProductReadModel),
        module(CategoryReadModel),
        module(ProductDemandReadModelMaker),
      ],
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~api,
      ~apiRole,
      ~scheduler,
    )
}
```

**Wiring steps in the plugin:**

1. **Build aggregates** — `Platform.Aggregate.Make(Spec, Behavior, EventMappings)`
2. **Collect projections** — create a `Mappings` module per read model, listing all mapping modules
3. **Build read models** — `Platform.ReadModel.Make(ReadModelSpec, Projections)`
4. **Compile EP mappings** — `ExtensionPointMapping.Make(EPSpec, AggregateMapping)` per aggregate, collect into array
5. **Build extension points** — `Platform.ExtensionPoint.Make(EPSpec, EPMappings)`
6. **Compile extension mappings** — `ExtensionMapping.Make(EPSpec, ExtensionMappingModule)` per mapping, collect into array
7. **Build extensions** — `Platform.Extension.Make(EPSpec, ExtensionMappings)`
8. **Assemble** — `Platform.Plugin.make(...)` with all components

The **projection Mappings boilerplate** follows a fixed pattern for every read model:
```rescript
module MyProjections: Mappings with module Target := MyReadModel = {
  module M = Mappings.Make(MyReadModel)
  module type Mapping = M.Mapping
  let mappings: array<module(Mapping)> = [module(MyProjections.SomeMapping)]
}
```

---

## Platform Package

The platform package wires plugins together and starts the application.

**`Main.res`**:
```rescript
module Platform = ReventlessInMemory.Platform.Make()

module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)
module Ordering = OrderingPlugin.OrderingPlugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
)
```

Note the **double namespace** when referencing plugin modules: `CatalogPlugin.CatalogPlugin.Make(Platform)`. The first `CatalogPlugin` is the package namespace, the second is the module name within that namespace.

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

**AWS split mode** works the same way — use `MakeWithConfig` on the AWS platform:

```rescript
module Platform = ReventlessAws.Platform.MakeWithConfig(
  {let api = appSyncApi; let apiRole = appSyncRole},
  {let splitApi = true},
)
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

## Conventions & Pitfalls

### Naming

- **Aggregate names** — singular nouns: `Product`, `Order`, `Customer`
- **Read model names** — plural nouns: `Products`, `Orders`, `Customers`
- **Commands** — imperative: `Add`, `UpdateName`, `Ship`, `Cancel`
- **Events** — past tense: `Added`, `NameUpdated`, `Shipped`, `Cancelled`
- **Extension point names** — dotted: `"Catalog.Products"`, `"Ordering.Orders"`

### Behavior patterns

- **Idempotency** — return `[]` when a command produces no change
- **`create` vs `execute`** — `create` handles the first command (no state exists), `execute` handles all subsequent commands
- **Error variants** — define explicit domain errors, not generic strings
- **`init` guard** — throw `InvalidEvent` for events that cannot create an aggregate

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

## DCB Approach

The **DCB** (Dynamic Consistency Boundary) approach is an alternative to the aggregate pattern. Instead of per-entity aggregates with private event streams, DCB uses a **shared event log** per bounded context. Commands are handled by **StateChangeSlices** (write-side) and queries by **StateViewSlices** (read-side). Both slice types read from the same event log, filtering events by tags.

The DCB example lives in `examples/online-shop-dcb/` and mirrors the same online-shop domain as the aggregate example.

### Key differences from the aggregate approach

| Aspect | Aggregates | DCB |
|--------|-----------|-----|
| Event storage | One event stream per aggregate instance | One shared event log per bounded context |
| Write-side | Behavior (`init`/`apply`/`create`/`execute`) | StateChangeSlice (`initialDecisionModel`/`reduce`/`decide`) |
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
```

Key points:
- **`@s.matches(DcbTag.string)`** — required on every entity ID field. Without it, queries return ALL events instead of filtering by entity, causing phantom state in decision models
- **Both command AND event types** need the tag annotation on entity ID fields
- For cross-entity commands, use `array<@s.matches(DcbTag.string) string>` on array fields that reference other entities (see [Cross-Entity Queries](#cross-entity-queries-tagged-arrays) below)
- All entity types (Product, Category, etc.) share the same event log
- The event log file has no `name` or `Id` — it's just a type definition

---

### StateChangeSlice

A StateChangeSlice handles commands using a **decision model** — a minimal projection of past events that captures only the information needed to accept or reject a command.

**`AddProduct.res`**:
```rescript
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

**StateChangeSlice spec fields:**

| Field | Purpose |
|-------|---------|
| `name` | Unique slice name |
| `module DcbEventLogSpec` | Links to the shared event log |
| `command` | Commands this slice handles (with `@s.matches` tags) |
| `error` | Domain error variants |
| `decisionModel` | Minimal state needed for command decisions |
| `initialDecisionModel` | Starting value before any events |
| `reduce` | Fold events into the decision model (like `apply` in aggregates) |
| `decide` | Accept or reject a command → `Ok(events)` or `Error(error)` |

**Contrast with aggregates:**
- `reduce` replaces `init` + `apply` — there's no separate creation path
- `decide` replaces `create` + `execute` — returns `Result` instead of using an error handler
- The decision model is typically much smaller than full aggregate state (e.g., `{exists: bool}` vs the entire product record)
- The `reduce` function receives ALL events from the log (filtered by entity ID tag), so use `| _ => model` to skip irrelevant ones

#### Cross-Entity Queries (Tagged Arrays)

When a command references multiple entities (e.g., PlaceOrder with a list of product IDs), annotate the array field with `@s.matches(DcbTag.string)` on its **elements**:

```rescript
@schema
type command =
  | PlaceOrder({
      orderId: @s.matches(DcbTag.string) string,
      customerId: string,
      productId: array<@s.matches(DcbTag.string) string>,
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

let project = (_, event) =>
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

The DCB plugin composition root is similar to the aggregate version, but uses different builder functors and includes a `DcbSpec` module that collects all slices.

**`CatalogPlugin.res`**:
```rescript
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // ── Event Log ──────────────────────────────────────────────
  module CatalogEventLogMaker = Platform.DcbEventLog.Make(CatalogEventLog)

  // ── StateChangeSlices (write-side) ─────────────────────────
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  // ... more slices ...

  // ── StateViewSlices (read-side) ────────────────────────────
  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)
  // ... more views ...

  // ── Extension Point (same pattern as aggregates) ────────────
  module ProductsEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtensionPointMapping,
  )
  // ... EP wiring ...

  // ── Extension (functor application + Mappings wrapper) ─────
  module OrdersDemandMapping = ReventlessInfra.ExtensionMapping.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtension.DemandMappingImpl,
  )
  module OrdersExtensionMappings = {
    module Spec = OrderingSpec.OrdersExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionMapping.T
      with module ExtensionPoint := Spec
    let name = "CatalogDemand"
    let mappings: array<module(Mapping)> = [module(OrdersDemandMapping)]
  }
  module OrdersExtensionMaker = Platform.Extension.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtensionMappings,
  )

  // ── DcbSpec: collect all slices for the plugin ─────────────
  module DcbSpec = {
    @schema
    type event = CatalogEventLog.event
    let stateChangeSlices: array<
      module(ReventlessInfra.StateChangeSlice.T with type dcbEvent = event),
    > = [
      module(AddProductSlice),
      module(ChangeProductNameSlice),
      // ... all write slices ...
    ]
    let stateViewSlices: array<
      module(ReventlessInfra.StateViewSlice.T with type dcbEvent = event),
    > = [
      module(ProductsViewSlice),
      // ... all view slices ...
    ]
    let automationSlices = []
    let outboundTranslationSlices = []
    let inboundTranslationSlices = []
  }

  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~api,
      ~apiRole,
      ~scheduler,
      ~dcbSpec=module(DcbSpec),   // ← DCB-specific: passes the slice collection
    )
}
```

**Key differences from aggregate plugin composition:**
- **`Platform.DcbEventLog.Make`** instead of `Platform.Aggregate.Make`
- **`Platform.StateChangeSlice.Make`** instead of aggregate + behavior
- **`Platform.StateViewSlice.Make`** instead of read model + projection mappings
- **`DcbSpec` module** collects all slices into typed arrays
- **`~dcbSpec=module(DcbSpec)`** passed to `Plugin.make` (aggregates don't have this)

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
open Reventless
open ReventlessInfra.ExtensionMapping

module Spec = OrderingSpec.OrdersExtensionPoint

module DemandMappingImpl = {
  module ExtensionPoint = Spec

  // DCB adapter: wraps StateChangeSlice as Aggregate.Spec
  module Aggregate = {
    let name = RecordProductDemand.name
    module Id = Id.String
    type command = RecordProductDemand.command
    let commandSchema = RecordProductDemand.commandSchema
    @schema type event = unit
    @schema type error = unit
  }

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Spec.ItemOrdered({productId, orderId}) => [
        PublishAggregateCommand(productId, RecordProductDemand.RecordDemand({productId, orderId})),
      ]
    | Spec.ItemOrderCancelled({productId, orderId}) => [
        PublishAggregateCommand(productId, RecordProductDemand.RevokeDemand({productId, orderId})),
      ]
    }

  let mapOutgoingEvent = None
}
```

The extension file exports only the mapping implementation — the functor application and `Mappings` wrapper are built in the plugin file (same as the aggregate approach).

The adapter pattern:
- **EP mapping**: The `Aggregate` shim exposes the event log's event type so `ExtensionPointMapping.Make` can decode outgoing events
- **Extension mapping**: The `Aggregate` shim exposes the target slice's command type and schema so `ExtensionMapping.Make` can encode routed commands
- Both shims use `unit` for unused types (commands in EP, events/errors in extensions)

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
│       └── Plugin/
│           ├── CatalogEventLog.res    # Shared event log type
│           └── CatalogPlugin.res      # Composition root
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

module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)
module Ordering = OrderingPlugin.OrderingPlugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
)
```

The **double namespace** pattern applies here too: `CatalogPlugin.CatalogPlugin.Make(Platform)` — the first part is the package namespace, the second is the module name within that namespace.

---

## Part 3: Hybrid Composition

The aggregate and DCB approaches can be mixed within a single plugin. `Plugin.make` accepts both `~aggregates` and `~dcbSpec` as optional parameters — entities that are self-contained use aggregates, while entities that share consistency boundaries use a DCB event log.

### When to Use Each Approach

| Use **aggregates** when | Use **DCB** when |
|------------------------|------------------|
| Entity is self-contained — commands only need the entity's own history | A command's validity depends on multiple entity types |
| Entity has a clear lifecycle state machine | The consistency boundary varies per command |
| No cross-entity consistency requirements at command time | Tag-based filtering provides a natural scope for events |
| Entity is high-volume and would create noise in a shared log | Complex cross-entity invariants exist within the plugin |

**Key constraint:** Entities that need cross-entity decisions **must** share the same DCB event log. An aggregate cannot participate in a DCB decision model, and a DCB slice cannot replay aggregate events.

### Hybrid Plugin Composition

A hybrid plugin passes both `~aggregates` and `~dcbSpec` to `Plugin.make`:

```rescript
// CatalogPlugin.res — hybrid: Category aggregate + Product/Demand DCB
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // --- Aggregate-based: Category (independent entity) ---
  module CategoryAggregate = Platform.Aggregate.Make(Category, CategoryBehavior)
  module CategoriesReadModelMaker = Platform.ReadModel.Make(CategoriesReadModel, CategoriesProjections)

  // --- DCB-based: Product + ProductDemand (cross-entity consistency) ---
  module DcbEventLogMaker = Platform.DcbEventLog.Make(CatalogEventLog)
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  // ... more slices

  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)

  module DcbSpec = {
    @schema type event = CatalogEventLog.event
    let stateChangeSlices = [module(AddProductSlice), module(ChangeProductNameSlice)]
    let stateViewSlices = [module(ProductsViewSlice), module(ProductDemandViewSlice)]
    let automationSlices = []
    let outboundTranslationSlices = []
    let inboundTranslationSlices = []
  }

  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~aggregates=[module(CategoryAggregate)],      // Aggregate components
      ~readModels=[module(CategoriesReadModelMaker)], // Aggregate read models
      ~dcbSpec=module(DcbSpec),                       // DCB slices
      ~api, ~apiRole, ~scheduler,
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
  let map = (msg) => switch msg.event {
  | Added({name}) => Create(msg.id, {categoryName: name})
  | _ => Ignore
  }
}

module CatalogDcbMapping = {
  let sourceName = "CatalogDcbEventLog"  // <pluginName> ++ "DcbEventLog"
  @schema type sourceEvent = CatalogEventLog.event
  type targetState = myState
  let map = (msg) => switch msg.event {
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
│   │   ├── CatalogEventLog.res       # DCB events (excludes Category)
│   │   └── CatalogPlugin.res         # Hybrid composition
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
