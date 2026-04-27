# Application Development Layers

Reventless organises application code into three strictly separated layers.
Each layer has a clearly defined responsibility, a fixed set of package
dependencies, and its own placement within the source tree.

```
┌─────────────────────────────────────────────────────────────────────┐
│  Layer 1 — Domain Specification                                     │
│  deps: reventless-spec only                                         │
│  Pure domain logic — commands, events, state, decisions             │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 2 — Plugin Assembly                                          │
│  deps: reventless-spec + reventless-infra                           │
│  Wires domain modules into a platform-agnostic plugin functor       │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 3 — Platform Composition Root                                │
│  deps: reventless-infra + reventless-aws OR reventless-in-memory    │
│  Instantiates a concrete Platform and produces deployable outputs   │
└─────────────────────────────────────────────────────────────────────┘
```

The dependency arrow always points downward. Layer 1 knows nothing about
infrastructure. Layer 2 knows the _shape_ of infrastructure (via `Platform.T`)
but not the _provider_. Layer 3 is the only place that names a specific
provider.

---

## Layer 1 — Domain Specification

### Purpose

Everything a domain expert would recognise: aggregate state machines, DCB
slices, read model projections, extension point contracts. No Pulumi, no AWS,
no Effect, no DynamoDB — only `sury` (for JSON schema derivation via the
`@schema` ppx) and the behavioral contracts from `reventless-spec`.

### Package dependencies

```json
"dependencies": [
  "sury",
  "@reventlessdev/reventless-spec"
]
```

`reventless-spec` provides `Aggregate.Spec`, `Behavior.T`, `ReadModel.Spec`,
`Projection`, `StateChangeSlice.Spec`, `StateViewSlice.Spec`,
`DcbEventLog.Spec`, `SideEffect.T`, `Handler.handler`, `Id`, `Message.meta`,
`Schedule`, `EventMapping.action`, etc. — every type that describes _what
the domain does_, with no infrastructure attached.

### What goes here

#### Aggregate-style: Spec + Behavior + Projections

**Aggregate Spec** (`Product.res`)

The spec module satisfies `Reventless.Aggregate.Spec`. It declares the
aggregate's `Id`, `name`, and the three domain types the framework needs:

```rescript
open Reventless
module Id = Id.String
let name = "Product"

@schema
type command =
  | AddProduct({productId: string, name: string, description: string, price: float})
  | UpdateProductName({productId: string, name: string})

@schema
type event =
  | ProductAdded({productId: string, name: string, description: string, price: float})
  | ProductNameUpdated({productId: string, name: string})

@schema
type error =
  | ProductAlreadyExists
  | ProductNotFound
```

The `@schema` ppx generates `commandSchema`, `eventSchema`, and `errorSchema`
— sury codecs used by the framework for serialisation, routing, and error
reporting. The app developer never writes these by hand.

**Aggregate Behavior** (`ProductBehavior.res`)

The behavior module satisfies `Reventless.Behavior.T`. It implements the
state machine: how to reconstruct state from events and how to process
commands:

```rescript
open Reventless
open Product

module Spec = Product

@schema
type state = {name: string, description: string, price: float}



let init = event =>
  switch event {
  | ProductAdded({name, description, price}) => {name, description, price}
  | _ => throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply = (state, event) =>
  switch event {
  | ProductAdded({name, description, price}) => {name, description, price}
  | ProductNameUpdated({name}) => {...state, name}
  | _ => state
  }

let create = (command, _context, errorHandler) =>
  switch command {
  | AddProduct({productId, name, description, price}) =>
    [ProductAdded({productId, name, description, price})]
  | _ => errorHandler(ProductNotFound, command, _context)
  }

let execute = (state, command, context, errorHandler) =>
  switch command {
  | AddProduct(_) => errorHandler(ProductAlreadyExists, command, context)
  | UpdateProductName({productId, name}) => [ProductNameUpdated({productId, name})]
  | _ => errorHandler(ProductNotFound, command, context)
  }
```

`create` is called when the aggregate does not yet exist (no prior events).
`execute` is called when the aggregate already has state.

**Read Model Spec** (`ProductsReadModel.res`)

Satisfies `Reventless.ReadModel.Spec`. Declares the query-side state shape:

```rescript
open Reventless
module Id = Id.String
let name = "Products"

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

**Projections** (`ProductsProjections.res`)

Maps aggregate events to read model mutations using `Reventless.Projection`:

```rescript
open Reventless
open Reventless.Projection

module ProductMapping = Mapping.Make(
  Product,           // source aggregate spec
  ProductsReadModel, // target read model spec
  {
    let map = ({Message.event: event, id, _}) =>
      switch event {
      | Product.ProductAdded({productId, name, description, price}) =>
        Set(id, {ProductsReadModel.productId, name, description, price})
      | Product.ProductNameUpdated({name}) =>
        Update(id, state => {...state, name})
      | _ => NoOp
      }
  },
)

module Mappings = Mappings.Make(ProductsReadModel)
let mappings: array<module(Mappings.Mapping)> = [module(ProductMapping)]
```

`Set`, `Update`, `Delete`, `Create`, and `NoOp` are the projection actions.
`Mapping.Make` enforces at compile time that the source spec and target spec
are compatible.

#### DCB-style: Event Log + State Change Slices + State View Slices

DCB (Dynamic Consistency Boundary) replaces per-aggregate event logs with a
single shared log whose events are tagged for efficient entity-scoped queries.

**Event Log Spec** (`CatalogEventLog.res`)

Satisfies `Reventless.DcbEventLog.Spec`. All events for the plugin live here,
tagged with `@s.matches(DcbTag.string)` on entity ID fields:

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
  | ProductNameUpdated({productId: @s.matches(DcbTag.string) string, name: string})
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})
```

The `@s.matches(DcbTag.string)` annotation marks fields that become DCB tags.
The framework uses these to scope event log queries to specific entities.

**State Change Slice** (`AddProduct.res`)

Satisfies `Reventless.StateChangeSlice.Spec`. Implements the decision logic
for one command type against the shared event log:

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
    if model.exists {Error(ProductAlreadyExists)}
    else {Ok([ProductAdded({productId, name, description, price})])}
  }
```

Each slice: (1) references the shared event log via `DcbEventLogSpec`; (2)
declares its own command type; (3) provides `reduce` to build a decision model
from relevant events; (4) provides `decide` to make the decision.

**State View Slice** (`ProductsView.res`)

Satisfies `Reventless.StateViewSlice.Spec`. Projects DCB events to a query
read model:

```rescript
open Reventless

let name = "ProductsView"
module DcbEventLogSpec = CatalogEventLog

@schema
type state = {name: string, description: string, price: float}

let project = (current, event) =>
  switch event {
  | CatalogEventLog.ProductAdded({productId, name, description, price}) =>
    [Projection.Spec.Set(productId, {name, description, price})]
  | CatalogEventLog.ProductNameUpdated({productId, name}) =>
    [Projection.Spec.Update(productId, s => {...s, name})]
  | _ => []
  }
```

#### Extension Point and Extension contracts

Cross-plugin communication is defined entirely in Layer 1. An **extension
point** is a stable public event/command API that a plugin publishes outward.
An **extension** is a mapping inside another plugin that subscribes to it.

**Extension Point Spec** (`ProductsExtensionPointSpec.res`)

```rescript
let name = "Catalog.Products"

@schema
type command = unit  // read-only EP: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
```

The `name` field is the runtime identifier that must match exactly on both the
publishing and subscribing side.

**Extension Point Mapping** (`ProductsExtensionPointMapping.res`)

Maps internal aggregate events to the public EP event API. Lives in the
publishing plugin's source tree and references `ReventlessInfra.ExtensionPointMapping`:

```rescript
open ReventlessInfra.ExtensionPointMapping

module ExtensionPoint = ProductsExtensionPointSpec
module Aggregate = Product  // the source aggregate spec

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Product.ProductAdded({productId, name, price}) =>
    [PublishEvent(productId, ProductsExtensionPointSpec.ProductBecameAvailable({productId, name, price}))]
  | Product.ProductPriceUpdated({productId, price}) =>
    [PublishEvent(productId, ProductsExtensionPointSpec.ProductPriceChanged({productId, price}))]
  | _ => []
  })
```

**Extension Mapping** (`ProductsExtension.res`)

Lives in the _subscribing_ plugin's source tree and translates incoming EP
events to aggregate commands:

```rescript
open ReventlessInfra.ExtensionMapping

module Spec = ProductsExtensionPointSpec

module ProductMappingImpl = {
  module ExtensionPoint = Spec
  module Aggregate = CatalogProduct  // target aggregate

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Spec.ProductBecameAvailable({productId, name, price}) =>
      [PublishAggregateCommand(productId, CatalogProduct.SyncNewProduct({productId, name, price}))]
    | Spec.ProductPriceChanged({productId, price}) =>
      [PublishAggregateCommand(productId, CatalogProduct.UpdateSyncedPrice({productId, price}))]
    }

  let mapOutgoingEvent = None
}

module ProductMappingT = Make(ProductMappingImpl)

module Mappings = {
  module Spec = Spec
  module type Mapping = T with module ExtensionPoint := Spec
  let name = "OrderingProducts"
  let mappings: array<module(Mapping)> = [module(ProductMappingT)]
}
```

### Summary of Layer 1 module types

| Module | Satisfies | Package |
|---|---|---|
| `Product.res` | `Reventless.Aggregate.Spec` | reventless-spec |
| `ProductBehavior.res` | `Reventless.Behavior.T` | reventless-spec |
| `ProductsReadModel.res` | `Reventless.ReadModel.Spec` | reventless-spec |
| `ProductsProjections.res` | mappings via `Reventless.Projection` | reventless-spec |
| `CatalogEventLog.res` | `Reventless.DcbEventLog.Spec` | reventless-spec |
| `AddProduct.res` | `Reventless.StateChangeSlice.Spec` | reventless-spec |
| `ProductsView.res` | `Reventless.StateViewSlice.Spec` | reventless-spec |
| `*ExtensionPointSpec.res` | EP name + event/command/directive | reventless-spec |
| `*ExtensionPointMapping.res` | `ReventlessInfra.ExtensionPointMapping` | reventless-infra |
| `*Extension.res` | `ReventlessInfra.ExtensionMapping` | reventless-infra |

> Note: `ExtensionPointMapping` and `ExtensionMapping` reference infra types
> (`ReventlessInfra.ExtensionPointMapping`, `ReventlessInfra.ExtensionMapping`)
> because their mapping actions (`PublishEvent`, `PublishAggregateCommand`)
> are infrastructure concepts. They are still logically part of the domain
> specification layer — they just touch the layer 1/2 boundary.

---

## Layer 2 — Plugin Assembly

### Purpose

The plugin module is a **functor** parameterised on `Platform.T`. It wires
Layer 1 domain modules into infrastructure components using the abstract
factory methods on `Platform`. The result is a fully wired plugin that works
against _any_ provider implementation of `Platform.T` — AWS, in-memory,
or a future alternative.

### Package dependencies

```json
"dependencies": [
  "sury",
  "@reventlessdev/reventless-spec",
  "@reventlessdev/reventless-infra"
]
```

`reventless-spec` is listed explicitly because ReScript does not auto-expose
transitive dependencies. Even though `reventless-infra` already depends on
`reventless-spec`, you need both entries to use both namespaces (`Reventless.*`
and `ReventlessInfra.*`).

### The Plugin functor

The plugin module always has the same shape:

```rescript
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // ... component assembly ...
}
```

`Platform.T` is the abstract factory interface defined in `reventless-infra`.
Inside the functor body, `Platform.Aggregate.Make`, `Platform.ReadModel.Make`,
`Platform.DcbEventLog.Make`, etc. are the only factory calls you make.
The concrete implementation (DynamoDB tables, SQS queues, Lambda functions,
or their in-memory counterparts) is never mentioned here.

### Aggregate-style plugin assembly

```rescript
open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {

  // ── Aggregates ─────────────────────────────────────────────────────
  module ProductAggregate = Platform.Aggregate.Make(
    Product,                                        // Aggregate.Spec
    ProductBehavior,                                // Behavior.T
    ReventlessInfra.NoEventMappings.Make(Product),  // no cross-aggregate event mappings
  )

  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    ReventlessInfra.NoEventMappings.Make(Category),
  )

  // ── Read Models ────────────────────────────────────────────────────
  // The Mappings wrapper is boilerplate that bridges the projection
  // array from Layer 1 to the ReadModel.Make functor.

  module ProductMappings: Mappings with module Target := ProductsReadModel = {
    module ProductMappings = Mappings.Make(ProductsReadModel)
    module type Mapping = ProductMappings.Mapping
    let mappings = ProductsProjections.mappings
  }
  module ProductReadModel = Platform.ReadModel.Make(ProductsReadModel, ProductMappings)

  // ── Extension Point (outbound — published by this plugin) ──────────
  module ProductsEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    ProductsExtensionPointMapping,
  )
  module ProductsEPMappings = {
    module Spec = ProductsExtensionPointSpec
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
  }
  module ProductsExtensionPoint =
    Platform.ExtensionPoint.Make(ProductsEPMappings)

  // ── Extension (inbound — subscribing to another plugin's EP) ───────
  module OrdersExtension =
    Platform.Extension.Make(OrdersExtension.Mappings)
}
```

### DCB-style plugin assembly

```rescript
module Make = (Platform: ReventlessInfra.Platform.T) => {

  // ── State Change Slices (write side) ──────────────────────────────
  module AddProductSlice          = Platform.StateChangeSlice.Make(AddProduct)
  module UpdateProductNameSlice   = Platform.StateChangeSlice.Make(UpdateProductName)
  module AddCategorySlice         = Platform.StateChangeSlice.Make(AddCategory)
  module RenameCategorySlice      = Platform.StateChangeSlice.Make(RenameCategory)

  // ── State View Slices (read side) ─────────────────────────────────
  module ProductsViewSlice    = Platform.StateViewSlice.Make(ProductsView)
  module CategoriesViewSlice  = Platform.StateViewSlice.Make(CategoriesView)

  // ── Extension Point (outbound) ─────────────────────────────────────
  module ProductsEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    ProductsExtensionPointMapping,
  )
  module ProductsEPMappings = {
    module Spec = ProductsExtensionPointSpec
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
  }
  module ProductsExtensionPoint =
    Platform.ExtensionPoint.Make(ProductsEPMappings)

  // ── Extension (inbound) ────────────────────────────────────────────
  module OrdersExtension =
    Platform.Extension.Make(OrdersExtension.Mappings)

  // The DCB event log itself is created internally by the platform from the
  // registered slices; plugins do not declare a `DcbEventLog.Make` module.
}
```

### Rules for Layer 2

- **Always a functor on `Platform.T`** — never hardcode `ReventlessAws.*` or
  `ReventlessInMemory.*` here.
- **Only `Platform.*` factory calls** for component creation. Never reach into
  `ReventlessCore.*` builders directly.
- **Domain types flow in, component types flow out** — `Platform.Aggregate.Make`
  takes a `Spec` from Layer 1 and produces an `Aggregate.T` from
  `reventless-infra`.
- **No runtime code** — plugin assembly is entirely deploy-time (Pulumi
  infrastructure construction). Callbacks and operations live inside
  `reventless-core` builders, invisible to this layer.
- **`NoEventMappings`** (`ReventlessInfra.NoEventMappings.Make`) is the
  default third argument for aggregates that do not receive events from other
  aggregates via event mapping.

### Platform factory methods at a glance

| Method | Layer 1 input | Output (ReventlessInfra type) |
|---|---|---|
| `Platform.Aggregate.Make` | `Spec`, `Behavior`, `EventMappings` | `Aggregate.T` |
| `Platform.ReadModel.Make` | `Spec`, `Mappings` | `ReadModel.T` |
| `Platform.ExtensionPoint.Make` | `Mappings` | `ExtensionPoint.T` |
| `Platform.Extension.Make` | `Mapping` | `Extension.Blueprint` |
| `Platform.Task.Make` | `Spec` | `Task.T` |
| `Platform.DcbEventLog.Make` | `Spec` | `DcbEventLog.T` |
| `Platform.StateChangeSlice.Make` | `Spec` | `StateChangeSlice.T` |
| `Platform.StateViewSlice.Make` | `Spec` | `StateViewSlice.T` |
| `Platform.Counter` | (pre-built) | `Counter.T` |

---

## Layer 3 — Platform Composition Root

### Purpose

The composition root instantiates a concrete `Platform.T` and applies the
plugin functor to it. This is the **only** file in an application that needs
to know which infrastructure provider is being used.

In test and local development, the provider is `reventless-in-memory`.
In production deployments, the provider is `reventless-aws`.

### Package dependencies

```json
// For tests / local development:
"dependencies": [
  "sury",
  "@reventlessdev/reventless-spec",
  "@reventlessdev/reventless-infra",
  "@reventlessdev/reventless-in-memory"
]
```

```json
// For production (Pulumi stack):
"dependencies": [
  "sury",
  "@reventlessdev/reventless-spec",
  "@reventlessdev/reventless-infra",
  "@reventlessdev/reventless-aws"
]
```

A single application package typically includes both `reventless-in-memory`
(for tests) and `reventless-aws` (for the Pulumi deployment entry point), with
the provider choice isolated to different files.

### In-memory composition (tests)

The in-memory platform is used in E2E tests and local development because it
needs no real AWS infrastructure. Each test creates its own isolated bus:

```rescript
// tests/E2E/CatalogE2ETest.res

module Bus = ReventlessInMemory.InMemory_Bus.Make()  // isolated bus for this test suite

let _ = ReventlessInMemory.TestRunner.setup()  // activate Pulumi mock mode

// Build the concrete Platform using the in-memory bus
module Platform = ReventlessInMemory.Platform.Make(Bus)

// Apply the plugin functor
module Catalog = CatalogPlugin.Plugin.Make(Platform)
```

The `InMemory_Bus.Make()` call creates a fresh, isolated message bus. All
component builders inside `CatalogPlugin.Make(Platform)` publish and subscribe
through this bus. Tests interact with the plugin via the bus directly:

```rescript
let catalog = Catalog.make()

testPromise("AddProduct stores state", async () => {
  let _ = await Bus.dispatchCommand("ProductCmdTopic", commandJson)
  let state = await Bus.getQueryDb("ProductsQueryDB")
  expect(state)->toBeSome
})
```

The in-memory platform mirrors the AWS platform's `Platform.T` signature
exactly. If your plugin functor compiles against the in-memory platform, it
will also compile against the AWS platform — the type system enforces this.

### AWS composition (Pulumi deployment)

In a production stack file, the composition root selects the AWS platform:

```rescript
// index.res  — the only file that imports reventless-aws

// Create the AWS platform (creates AppSync API internally)
module Platform = ReventlessAws.Platform.Make()

// Apply the plugin functor — identical call to the test version
module Catalog  = CatalogPlugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)
```

The `CatalogPlugin.Plugin.Make` call is identical in tests and in production. Only
the `Platform` module changes.

### Why a single composition root matters

Keeping the provider selection in one file means:

- All other source files are testable with `reventless-in-memory` without
  any conditional compilation or environment flags.
- Switching providers (e.g. a future `reventless-azure`) requires changing
  only `index.res`.
- The type checker guarantees that your plugin's `Make` functor satisfies the
  provider's implementation of `Platform.T` — if it doesn't, you get a
  compile error at the composition root, not a runtime failure.

---

## Complete worked example: an aggregate-style plugin

This shows how a minimal two-aggregate plugin moves from spec to deployment.

### Step 1 — Domain spec files (Layer 1, `reventless-spec` only)

```
src/
  Aggregate/
    Item.res          ← Aggregate.Spec: command/event/error types
    ItemBehavior.res  ← Behavior.T: state, init, apply, create, execute
  ReadModel/
    ItemsReadModel.res     ← ReadModel.Spec: state type + config
    ItemsProjections.res   ← Projection.Mapping: events → read model mutations
```

**Item.res**
```rescript
open Reventless
module Id = Id.String
let name = "Item"

@schema type command = | CreateItem({itemId: string, name: string})
                       | RenameItem({itemId: string, name: string})
@schema type event   = | ItemCreated({itemId: string, name: string})
                       | ItemRenamed({itemId: string, name: string})
@schema type error   = | ItemAlreadyExists | ItemNotFound
```

**ItemBehavior.res**
```rescript
open Reventless
open Item
module Spec = Item

@schema type state = {name: string}


let init = event => switch event {
  | ItemCreated({name}) => {name}
  | _ => throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
}
let apply = (state, event) => switch event {
  | ItemCreated({name}) | ItemRenamed({name}) => {name}
}
let create = (command, _ctx, err) => switch command {
  | CreateItem({itemId, name}) => [ItemCreated({itemId, name})]
  | _ => err(ItemNotFound, command, _ctx)
}
let execute = (state, command, ctx, err) => switch command {
  | CreateItem(_) => err(ItemAlreadyExists, command, ctx)
  | RenameItem({itemId, name}) if name == state.name => []
  | RenameItem({itemId, name}) => [ItemRenamed({itemId, name})]
}
```

**ItemsReadModel.res**
```rescript
open Reventless
module Id = Id.String
let name = "Items"
@schema type state = {name: string}
open Reventless.ReadModel
let config = config()
let subIdConfig = None
```

**ItemsProjections.res**
```rescript
open Reventless.Projection
module ItemMapping = Mapping.Make(Item, ItemsReadModel, {
  let map = ({Message.event: event, id, _}) => switch event {
    | Item.ItemCreated({name}) => Create(id, {ItemsReadModel.name})
    | Item.ItemRenamed({name}) => Update(id, _ => {name})
  }
})
module M = Mappings.Make(ItemsReadModel)
let mappings: array<module(M.Mapping)> = [module(ItemMapping)]
```

### Step 2 — Plugin assembly (Layer 2, adds `reventless-infra`)

```
src/
  ItemsPlugin.res   ← functor Make(Platform: ReventlessInfra.Platform.T)
```

**ItemsPlugin.res**
```rescript
open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  module ItemAggregate = Platform.Aggregate.Make(
    Item,
    ItemBehavior,
    ReventlessInfra.NoEventMappings.Make(Item),
  )

  module ItemMappings: Mappings with module Target := ItemsReadModel = {
    module M = Mappings.Make(ItemsReadModel)
    module type Mapping = M.Mapping
    let mappings = ItemsProjections.mappings
  }
  module ItemReadModel = Platform.ReadModel.Make(ItemsReadModel, ItemMappings)
}
```

### Step 3 — Composition root (Layer 3, adds provider)

**tests/E2E/ItemsTest.res** — in-memory for tests
```rescript
module Bus      = ReventlessInMemory.InMemory_Bus.Make()
let _           = ReventlessInMemory.TestRunner.setup()
module Platform = ReventlessInMemory.Platform.Make(Bus)
module Items    = ItemsPlugin.Plugin.Make(Platform)
```

**index.res** — AWS for production
```rescript
module Platform = ReventlessAws.Platform.Make()
module Items    = ItemsPlugin.Plugin.Make(Platform)
```

---

## Common mistakes

### Importing a provider in Layer 1 or 2

```rescript
// ✗ WRONG — importing a concrete provider in a domain or assembly file
open ReventlessInMemory
module ItemAggregate = Aggregate_Builder.Make(Bus)
```

This couples your domain code to a specific provider. Use the `Platform.T`
functor pattern instead.

### Opening `Reventless` in the plugin functor when not needed

```rescript
// ✗ Causes warning 33 (unused open) in DCB plugins that use no Projection types
open Reventless
module Make = (Platform: ReventlessInfra.Platform.T) => { ... }
```

For DCB-style plugins that use only `Platform.*` calls with no `Projection`
types, no top-level `open` is needed. For aggregate-style plugins that use
`Projection.Mappings` in the assembly, `open Reventless.Projection` suffices.

### Duplicating the extension point spec

Both sides of a cross-plugin communication must use the **same `name`** value.
Copy the spec file to the subscribing plugin's source tree and keep it in sync
by name. The runtime matches extension points by `name` — a mismatch means
events are silently undelivered.

### Forgetting `reventless-spec` in `rescript.json`

ReScript does not auto-expose transitive dependencies. Even though
`reventless-infra` already depends on `reventless-spec`, you must list both
in your `rescript.json`:

```json
"dependencies": [
  "@reventlessdev/reventless-spec",
  "@reventlessdev/reventless-infra"
]
```

Without `reventless-spec`, the `Reventless.*` namespace is unavailable and
your domain spec files will fail to compile.

---

## Dependency reference

| Layer | `reventless-spec` | `reventless-infra` | `reventless-aws` | `reventless-in-memory` |
|---|:---:|:---:|:---:|:---:|
| 1 — Domain spec | ✓ | — | — | — |
| 2 — Plugin assembly | ✓ | ✓ | — | — |
| 3 — Composition root (test) | ✓ | ✓ | — | ✓ |
| 3 — Composition root (prod) | ✓ | ✓ | ✓ | — |
