---
title: DCB Slices
sidebar_position: 5
---

# DCB Slices

**DCB (Dynamic Consistency Boundary) Slices** use a **shared event log** across multiple state change slices with optimistic concurrency control. Instead of a per-entity event stream, all slices share one log and use **DCB tags** to filter relevant events.

## When to Use DCB Slices

Use DCB Slices when:
- Commands need consistency across multiple related entities
- Multiple commands might affect the same entities concurrently
- You want optimistic concurrency control rather than sequential processing
- A single event log should serve multiple independent state change operations

## Architecture

```d2
Client: Client { class: client }
CommandTopic: "DCB Command Topic\n(SQS)" { class: command-topic }
FilteringHandler: "Filtering Handler\n(Lambda)"
Slice1: AddProduct Slice { class: state-change-slice }
Slice2: ChangeProductName Slice { class: state-change-slice }
Slice3: ChangeProductPrice Slice { class: state-change-slice }
DcbEventLog: "DcbEventLog\n(Shared Event Log)" { class: dcb-event-log }
ViewSlice1: "StateViewSlice\n(Lambda)" { class: state-view-slice }
QueryDb: "Query DB\n(DynamoDB)" { class: query-db }

Client -> CommandTopic: { class: command-flow }
CommandTopic -> FilteringHandler: { class: command-flow }
FilteringHandler -> Slice1: { class: command-flow }
FilteringHandler -> Slice2: { class: command-flow }
FilteringHandler -> Slice3: { class: command-flow }
Slice1 -> DcbEventLog: { class: event-flow }
Slice2 -> DcbEventLog: { class: event-flow }
Slice3 -> DcbEventLog: { class: event-flow }
DcbEventLog -> ViewSlice1: { class: event-flow }
ViewSlice1 -> QueryDb: project { class: projection-flow }
```

## Key Concepts

### DCB Tags

Fields ending in `Id` with type `string` are automatically annotated as DCB tags — no manual work needed. Inside any `*Slice/` folder this happens automatically via `@@reventless.spec`; for files outside such folders, opt in with the `@@reventless.dcbTags` annotation. Under the hood, each tagged field gets `@s.matches(Reventless.DcbTag.string)`. This also applies to `*Id: array<string>` and `*Ids: array<string>` fields (element types are tagged). Tags are indexed in the shared event log, allowing each slice to efficiently query only the events relevant to its state (e.g., all events for a specific `itemId`).

When a variant has multiple `*Id` fields, use `@partitionTag` on the field that should be the partition key. For a composite key built from multiple fields joined in declaration order, use `@compositePartitionTag` on each contributing field — see [PPX annotations](./rescript-syntax.md#reventless-ppx-annotations).

### Decision State

Each `StateChangeSlice` builds a **state** by reading and folding relevant events from the shared log. The state captures the minimal information needed to accept or reject a command.

### Optimistic Concurrency

When appending events, the DCB event log checks that no conflicting events were written since the decision model was built. If a conflict is detected, the command handler retries.

## Building with DCB Slices

The following example builds the **Catalog plugin** step by step using DCB, focusing on products. Products can be added and renamed.

:::info Shared Event Log
There is no separate event log spec file. The framework creates one shared event log per plugin (named after the plugin, e.g. `"CatalogDcbEventLog"`). Each slice declares the subset of events it needs via `consumedEvent` — the DCB infrastructure uses these to efficiently filter the log.
:::

### Step 1: Implement StateChangeSlice Specs

Each `StateChangeSlice` lives in two files inside a `StateChangeSlice/` folder:

- **`<Name>.res`** (`@@reventless.spec`) — declares `consumedEvent`, `command`, `error`, and `event`
- **`<Name>_Behavior.res`** (`@@reventless.behavior`) — declares `state`, `initialState`, `evolve`, and `decide`

What each type means:

- **`consumedEvent`** — the subset of shared log events this slice reads (can be a strict subset of the full event payload)
- **`state`** / **`initialState`** — the minimal state built by folding `consumedEvent`s
- **`evolve`** — folds one `consumedEvent` into the state
- **`event`** — the event type this slice can emit
- **`decide`** — accepts or rejects the command, returning events or an error

The `@schema` annotation on `type command` automatically generates the command schema, which the framework uses to route commands to the correct slice. Inside a `StateChangeSlice/` folder, `@s.matches(Reventless.DcbTag.string)` is auto-applied to every `*Id` field.

```rescript
// AddProduct.res
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded

@schema
type command =
  | AddProduct({productId: string, name: string, description: string, price: float})

@schema
type error = ProductAlreadyExists

@schema
type event =
  | ProductAdded({productId: string, name: string, description: string, price: float})
```

```rescript
// AddProduct_Behavior.res
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

A slice can subscribe to multiple events and use a richer `consumedEvent` payload. Here `ChangeProductName` reads both `ProductAdded` (to track existence and current name) and `ProductNameChanged` (to track renames), but only needs the `name` field from each:

```rescript
// ChangeProductName.res
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({name: string})
  | ProductNameChanged({name: string})

@schema
type command = ChangeProductName({productId: string, name: string})

@schema
type error = ProductNotFound

@schema
type event = ProductNameChanged({productId: string, name: string})
```

```rescript
// ChangeProductName_Behavior.res
@@reventless.behavior

type state = {exists: bool, currentName: string}

let initialState = {exists: false, currentName: ""}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({name}) => {exists: true, currentName: name}
  | ProductNameChanged({name}) => {...state, currentName: name}
  }

let decide = (state, command) =>
  switch command {
  | ChangeProductName({productId, name}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if name == state.currentName {
      Ok([]) // idempotent — name unchanged
    } else {
      Ok([ProductNameChanged({productId, name})])
    }
  }
```

### Step 2: Implement a StateViewSlice

A `StateViewSlice` projects events from the shared log into a queryable read model. Like a StateChangeSlice it is two files, inside a `StateViewSliceStream/` folder:

- **`<Name>.res`** (`@@reventless.spec`) — declares `consumedEvent` and the read model `state`
- **`<Name>_Projection.res`** (`@@reventless.projection`) — declares `project`

The `project` function takes a `consumedEvent` and returns an **array** of projection actions. `Set`/`Update`/`UpdateWithDefault`/`Delete` are in scope without a `Projection.` prefix (the PPX opens `Reventless.Projection`). State-dependent updates use `Update(id, state => ...)` rather than receiving the existing state directly.

```rescript
// Products.res
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string, description: string, price: float})
  | ProductNameChanged({productId: string, name: string})
  | ProductDescriptionChanged({productId: string, description: string})
  | ProductPriceChanged({productId: string, price: float})

@schema
type state = {productId: string, name: string, description: string, price: float}
```

```rescript
// Products_Projection.res
@@reventless.projection

let project = ({event}) =>
  switch event {
  | ProductAdded({productId, name, description, price}) => [
      Set(productId, {productId, name, description, price}),
    ]
  | ProductNameChanged({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductDescriptionChanged({productId, description}) => [
      Update(productId, state => {...state, description}),
    ]
  | ProductPriceChanged({productId, price}) => [Update(productId, state => {...state, price})]
  }
```

### Step 3: Assemble the Plugin

The plugin's composition root, `src/Plugin.res`, is **generated** by `generate-plugin` before each build — you do not write it by hand. It is a [module function](./rescript-syntax.md#functors) over `Platform.T`. The generator pairs each spec with its body file via two-argument functor calls (`Make(Spec, Behavior)` for state-change slices, `Make(Spec, Projection)` for view slices) and passes the resulting modules to `Plugin.make`.

```rescript
// Plugin.res — AUTO-GENERATED

module Make = (Platform: ReventlessInfra.Platform.T) => {
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName, ChangeProductName_Behavior)

  module ProductsStreamSlice = Platform.StateViewSliceStream.Make(Products, Products_Projection)

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=5,
      ~stateChangeSlices=[module(AddProductSlice), module(ChangeProductNameSlice)],
      ~stateViewSlices=[module(ProductsStreamSlice)],
    )
}
```

### Sync vs async command dispatch

By default, slice mutations are dispatched **synchronously**: the AppSync resolver invokes the DCB Lambda, the slice handler runs inline, and the mutation resolves to `CommandAccepted` or `CommandRejected`. The plugin generator emits `Platform.StateChangeSlice.Make(...)`.

For slices that should publish-and-forget (high contention, long-running handlers, callers polling `Subscription.onX` for the outcome), add the `@@reventless.async` attribute to the slice spec file:

```rescript title="HighContentionSlice.res" showLineNumbers
@@reventless.spec
@@reventless.async

@schema
type consumedEvent = ...

@schema
type command = ...

@schema
type error = ...

@schema
type event = ...
```

The generator then emits `Platform.StateChangeSlice.MakeAsync(...)` instead. Async slices share a per-plugin `<Plugin>DcbAsyncCmdHandler` Lambda (FIFO-backed); sync slices stay on the default `<Plugin>DcbCmdHandler` Lambda. The async Lambda is only provisioned when at least one slice opts in — sync-only setups pay no extra Lambda cost.

See [CommandTopic](/framework/runtime-components/commandtopic#sync-vs-async) for the channel-level details.

## Deploying the Plugin

The platform package's `Main.res` instantiates the generated plugin functor as `<Namespace>.Plugin.Make(Platform)` and registers it:

```rescript
// Main.res — composition root

module Platform = ReventlessAws.Platform.Make(Config)
module Catalog = CatalogPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog)],
)
```

## Comparison: StateChangeSlice vs Aggregate

| Aspect | Aggregate | StateChangeSlice |
|--------|-----------|------------------|
| Event log | One per aggregate | Shared across all slices |
| Consistency boundary | Per aggregate instance | Per command (optimistic) |
| Concurrency | Sequential per instance | Optimistic concurrency |
| Decision logic | State machine (initialState/evolve/decide) | Minimal state (initialState/evolve/decide) |
| Cross-entity consistency | No | Yes (via shared log) |

## Next Steps

- [Plugin System Overview](./plugin-system.md) - Understand the full plugin system
- [Aggregates](./aggregates.md) - Learn about the Aggregate approach for self-contained entities
