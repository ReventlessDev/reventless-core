# Platform & Plugin Guide

This guide walks through building platforms with plugins using Reventless. It covers both the **aggregate** and **DCB** (Decision-Causation-Based) approaches, using the **online-shop** examples (`examples/online-shop-aggregates/`, `examples/online-shop-dcb/`).

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
7. [Cross-Plugin Communication](#cross-plugin-communication)
8. [Conventions & Pitfalls](#conventions--pitfalls)

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
  let make = (
    ~scheduler: Pulumi.Output.t<ReventlessInfra.Scheduler.operations>,
    ~api: Platform.api,
    ~apiRole: Platform.role,
  ) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~version="1.0.0",
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
// 1. Activate Pulumi mock mode (for in-memory / local dev)
let _ = ReventlessInMemory.TestRunner.setup()

// 2. Create the in-memory platform
module Platform = ReventlessInMemory.Platform.Make()

// 3. Apply plugin modules to the platform
module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)
module Ordering = OrderingPlugin.OrderingPlugin.Make(Platform)

// 4. Create a shared scheduler
let scheduler = Platform.makeScheduler()

// 5. Build plugin components
let catalogPlugin = Catalog.make(~scheduler, ~api=(), ~apiRole=())
let orderingPlugin = Ordering.make(~scheduler, ~api=(), ~apiRole=())

// 6. Build Core
let core = Platform.Core.make(
  ~version="1.0.0",
  ~extensionPoints=[],
  ~aggregates=[],
  ~readModels=[],
  ~scheduler,
  ~api=(),
  ~apiRole=(),
  ~resourceNaming=ReventlessInMemory.InMemory_PluginSpec.resourceNaming,
)

// 7. Wire everything together
Platform.makePlatform(
  ~api=Obj.magic(),
  ~core,
  ~plugins=[catalogPlugin, orderingPlugin],
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
- **Payload-less events** (e.g., `| Shipped`) — these serialize as JSON strings, which can cause round-trip issues with `splitMessage`/`combineMessage`. Prefer `| Shipped` only when no payload is needed and you've verified serialization works
- **Stale build cache** — after renaming or moving files, run `npx rescript clean` then rebuild
