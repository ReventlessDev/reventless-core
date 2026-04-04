---
title: DCB-Based Plugin
date: 2025-01-01
draft: false
sidebar_position: 5
---

# DCB-Based Plugin

A DCB-Based Plugin (Dynamic Consistency Boundary) uses a **shared event log** across multiple state change slices with optimistic concurrency control. Instead of a per-aggregate event stream, all slices share one log and use **DCB tags** to filter relevant events.

## When to Use

Choose the DCB-Based approach when:
- You need consistency across multiple related operations within a plugin
- Multiple commands might affect the same entities concurrently
- You want optimistic concurrency control rather than sequential processing
- A single event log should serve multiple independent state change operations

## Architecture

```d2
Client: Client { class: client }
CommandTopic: "DCB Command Topic\n(SQS FIFO)" { class: command-topic }
FilteringHandler: "Filtering Handler\n(Lambda)"
Slice1: CreateItem Slice { class: state-change-slice }
Slice2: RenameItem Slice { class: state-change-slice }
Slice3: DeleteItem Slice { class: state-change-slice }
DcbEventLog: "DcbEventLog\n(Shared Event Log)" { class: dcb-event-log }
ViewSlice1: "StateViewSlice\n(Lambda + DynamoDB)" { class: state-view-slice }

Client -> CommandTopic: { class: command-flow }
CommandTopic -> FilteringHandler: { class: command-flow }
FilteringHandler -> Slice1: { class: command-flow }
FilteringHandler -> Slice2: { class: command-flow }
FilteringHandler -> Slice3: { class: command-flow }
Slice1 -> DcbEventLog: { class: event-flow }
Slice2 -> DcbEventLog: { class: event-flow }
Slice3 -> DcbEventLog: { class: event-flow }
DcbEventLog -> ViewSlice1: { class: projection-flow }
```

## Key Concepts

### DCB Tags

Fields ending in `Id` with type `string` are automatically annotated as DCB tags by the `@@reventless.dcbTags` PPX annotation — no manual work needed. Under the hood, each tagged field gets `@s.matches(DcbTag.string)`. This also applies to `*Id: array<string>` and `*Ids: array<string>` fields (element types are tagged). Tags are indexed in the shared event log, allowing each slice to efficiently query only the events relevant to its state (e.g., all events for a specific `itemId`).

When a variant has multiple `*Id` fields, use `@partitionTag` on the field that should be the partition key — see the [PPX guide](../../guides/reventless-ppx.md#partitiontag-notag-dcbtag--field-level-dcb-tag-control).

### Decision State

Each `StateChangeSlice` builds a **state** by reading and folding relevant events from the shared log. The state captures the minimal information needed to accept or reject a command.

### Optimistic Concurrency

When appending events, the DCB event log checks that no conflicting events were written since the decision model was built. If a conflict is detected, the command handler retries.

## Building a DCB-Based Plugin

The following example builds an **Item Catalog** plugin using DCB. Items can be created, renamed, and deleted.

### Step 1: Define the Shared Event Log Spec

The `Reventless.DcbEventLog.Spec` requires only a single `@schema type event`. Every field that should act as a DCB tag must be annotated with `@s.matches(DcbTag.string)` (or `DcbTag.int`). These tags are extracted and stored alongside each event for efficient querying. The `@@reventless.dcbTags` annotation auto-injects `@s.matches(Reventless.DcbTag.string)` on all `*Id: string` fields — see the [Reventless PPX Guide](/guides/reventless-ppx#reventlessdcbtags).

```rescript
// ItemEventLogSpec.res
@@reventless.dcbTags

@schema
type event =
  | ItemCreated({itemId: string, name: string})
  | ItemRenamed({itemId: string, newName: string})
  | ItemDeleted({itemId: string})
```

All variant constructors must have a payload. Payload-less variants (e.g., `| SomeEvent`) serialize as JSON strings and are not handled correctly by the DCB infrastructure.

### Step 2: Implement StateChangeSlice Specs

Each `StateChangeSlice` handles one command type (or a related group). The spec implements `Reventless.StateChangeSlice.Spec`:

- **`state`** / **`initialState`** — the minimal state built from past events
- **`evolve`** — folds a DCB event into the state
- **`decide`** — accepts or rejects the command, returning events or an error

The `@schema` annotation on `type command` automatically generates `commandSchema`, which the framework uses to route commands to the correct slice.

```rescript
// CreateItemSpec.res
@@reventless.spec
@@reventless.dcbTags

module DcbEventLogSpec = ItemEventLogSpec

@schema
type command =
  | CreateItem({itemId: string, name: string})

@schema
type error =
  | ItemAlreadyExists

type state = {exists: bool}
let initialState = {exists: false}

// Build the decision model by folding relevant events
let evolve = (state, event) =>
  switch event {
  | ItemEventLogSpec.ItemCreated(_) => {exists: true}
  | ItemEventLogSpec.ItemDeleted(_) => {exists: false}
  | _ => model
  }

// Accept or reject the command based on the decision model
let decide = (model, command) =>
  switch command {
  | CreateItem({itemId, name}) =>
    if model.exists {
      Error(ItemAlreadyExists)
    } else {
      Ok([ItemEventLogSpec.ItemCreated({itemId, name})])
    }
  }
```

```rescript
// RenameItemSpec.res
@@reventless.spec
@@reventless.dcbTags

module DcbEventLogSpec = ItemEventLogSpec

@schema
type command =
  | RenameItem({itemId: string, newName: string})

@schema
type error =
  | ItemNotFound

type state = {exists: bool}
let initialState = {exists: false}

let evolve = (state, event) =>
  switch event {
  | ItemEventLogSpec.ItemCreated(_) => {exists: true}
  | ItemEventLogSpec.ItemDeleted(_) => {exists: false}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | RenameItem({itemId, newName}) =>
    if !model.exists {
      Error(ItemNotFound)
    } else {
      Ok([ItemEventLogSpec.ItemRenamed({itemId, newName})])
    }
  }
```

```rescript
// DeleteItemSpec.res
@@reventless.spec
@@reventless.dcbTags

module DcbEventLogSpec = ItemEventLogSpec

@schema
type command =
  | DeleteItem({itemId: string})

@schema
type error =
  | ItemNotFound

type state = {exists: bool}
let initialState = {exists: false}

let evolve = (state, event) =>
  switch event {
  | ItemEventLogSpec.ItemCreated(_) => {exists: true}
  | ItemEventLogSpec.ItemDeleted(_) => {exists: false}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | DeleteItem({itemId}) =>
    if !model.exists {
      Error(ItemNotFound)
    } else {
      Ok([ItemEventLogSpec.ItemDeleted({itemId})])
    }
  }
```

### Step 3: Implement a StateViewSlice Spec

A `StateViewSlice` projects events from the shared log into a queryable read model state. The spec implements `Reventless.StateViewSlice.Spec`.

The `project` function takes a `consumedEvent` and returns an **array** of `Reventless.Projection.action` values. State-dependent updates use `Update(id, state => ...)` rather than receiving the existing state directly.

```rescript
// ItemViewSpec.res
@@reventless.spec

open Reventless.Projection

module DcbEventLogSpec = ItemEventLogSpec

// Declare only the events this slice cares about
@schema
type consumedEvent =
  | ItemCreated({itemId: string, name: string})
  | ItemRenamed({itemId: string, newName: string})
  | ItemDeleted({itemId: string})

// The read-side state stored per item
@schema
type state = {
  itemId: string,
  name: string,
}

// Project DCB events into read model actions
let project = event =>
  switch event {
  | ItemCreated({itemId, name}) => [Set(itemId, {itemId, name})]
  | ItemRenamed({itemId, newName}) => [Update(itemId, state => {...state, name: newName})]
  | ItemDeleted({itemId}) => [Delete(itemId)]
  }
```

### Step 4: Assemble the Plugin

The Plugin is assembled as a **[module function](./rescript-syntax.md#functors) over `Platform.T`**. Slices are built using `Platform.StateChangeSlice.Make` and `Platform.StateViewSlice.Make`, then passed directly to `Plugin.make`.

```rescript
// ItemCatalogPlugin.res
// Imports only `reventless-spec`, not `reventless` or `reventless-aws`

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Build each StateChangeSlice from its spec
  module CreateItem = Platform.StateChangeSlice.Make(CreateItemSpec)
  module RenameItem = Platform.StateChangeSlice.Make(RenameItemSpec)
  module DeleteItem = Platform.StateChangeSlice.Make(DeleteItemSpec)

  // Build the StateViewSlice
  module ItemView = Platform.StateViewSlice.Make(ItemViewSpec)

  // Pass slices directly to Plugin.make — no DcbSpec bundle needed
  let make = () =>
    Platform.Plugin.make(
      ~name="ItemCatalog",
      ~heartbeatInterval=60,
      ~stateChangeSlices=[module(CreateItem), module(RenameItem), module(DeleteItem)],
      ~stateViewSlices=[module(ItemView)],
    )
}
```

## Deploying the Plugin

```rescript
// index.res — composition root

module Platform = ReventlessAws.Platform.Make(Config)
module App = ItemCatalogPlugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(App)],
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
- [Aggregate-Based Plugin](./aggregate-based-plugin.md) - Learn about the alternative Aggregate approach
