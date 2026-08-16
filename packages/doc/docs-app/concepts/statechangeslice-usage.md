---
title: StateChangeSlice Usage
date: 2026-02-17
draft: false
---

This guide covers how to use StateChangeSlice in your Reventless application. For the component reference, see [StateChangeSlice](../components/statechangeslice.md).

## Usage Pattern

A StateChangeSlice is **two files** living in a `StateChangeSlice/` folder: a spec file (`<Name>.res`) declaring the types, and a behavior file (`<Name>_Behavior.res`) holding the decision logic. The plugin generator wires them together — you never call a builder by hand.

### Defining the Spec

The spec file carries `@@reventless.spec`, which auto-injects `let name`, `module Id`, and `let moduleUrl` from the filename. A slice declares its own `consumedEvent` (the events it reads to rebuild state) and `event` (the events it produces) — there is no shared `DcbEventLogSpec` module.

```rescript title="CreateItem.res"
@@reventless.spec

@schema
type consumedEvent =
  | ItemCreated

@schema
type command =
  | CreateItem({itemId: string, name: string})

@schema
type error =
  | ItemAlreadyExists
  | InvalidName

@schema
type event =
  | ItemCreated({itemId: string, name: string})
```

Because this file lives inside a `StateChangeSlice/` folder, the PPX auto-applies `@s.matches(Reventless.DcbTag.string)` to every `*Id` field — never write it by hand.

### Defining the Behavior

The behavior file carries `@@reventless.behavior`, which auto-injects `open Spec` and `module Spec` (resolved from the `_Behavior` filename). You provide `state`, `initialState`, `evolve`, and `decide`.

```rescript title="CreateItem_Behavior.res"
@@reventless.behavior

type state = {exists: bool}

let initialState = {exists: false}

let evolve = (_state, event) =>
  switch event {
  | ItemCreated => {exists: true}
  }

let decide = (state, command) =>
  switch command {
  | CreateItem({itemId, name}) =>
    if name->String.length < 1 {
      Error(InvalidName)
    } else if state.exists {
      Error(ItemAlreadyExists)
    } else {
      Ok([ItemCreated({itemId, name})])
    }
  }
```

### Wiring the Slice

Wiring is generated into `Plugin.res` as a two-argument functor call — spec first, behavior second:

```rescript title="Plugin.res (generated)"
module CreateItemSlice = Platform.StateChangeSlice.Make(CreateItem, CreateItem_Behavior)
```

The generator:
1. Pairs the spec with its behavior via `Platform.StateChangeSlice.Make`
2. Sets up JSON command decoding from the slice's `command` type
3. Registers the handler in the plugin's CommandTopic registry

## Decision Model Pattern

`evolve`/`decide` are the key abstraction that makes StateChangeSlice powerful. `evolve` folds the slice's `consumedEvent` stream into `state`; `decide` validates a command against that state and returns the `event`s to append.

```rescript title="ReserveItem_Behavior.res — inventory management"
type state = {
  quantity: int,
  reserved: int,
  available: int,
}

let initialState = {quantity: 0, reserved: 0, available: 0}

let evolve = (state, event) =>
  switch event {
  | StockReceived({qty}) => {
      ...state,
      quantity: state.quantity + qty,
      available: state.available + qty,
    }
  | ItemReserved({qty}) => {
      ...state,
      reserved: state.reserved + qty,
      available: state.available - qty,
    }
  | ReservationReleased({qty}) => {
      ...state,
      reserved: state.reserved - qty,
      available: state.available + qty,
    }
  }

let decide = (state, command) =>
  switch command {
  | ReserveItem({itemId, qty}) =>
    if qty > state.available {
      Error(InsufficientStock(state.available))
    } else {
      Ok([ItemReserved({itemId, qty})])
    }
  }
```

The `consumedEvent` type lists exactly the variants this slice reads, so `evolve` matches them exhaustively — no catch-all is needed. Events from sibling slices that aren't in `consumedEvent` simply never reach this `evolve`.

## Integration with Plugin

Slices are wired into the generated `Plugin.res` and passed to `Platform.Plugin.make` via the `~stateChangeSlices` array — no `DcbSpec` wrapper needed:

```rescript title="Plugin.res (generated)"
// Inside the plugin's Make functor:
let make = () =>
  Platform.Plugin.make(
    ~name="MyPlugin",
    ~heartbeatInterval=5,
    ~stateChangeSlices=[
      module(CreateItemSlice),
      module(RenameItemSlice),
      module(DeleteItemSlice),
    ],
    // ...other component arrays...
  )
```

## DCB Tags

StateChangeSlice uses DCB tags for efficient event queries. In slice files the PPX auto-injects `@s.matches(DcbTag.string)` on all `*Id: string` fields — no manual annotation needed:

```rescript
// In a StateChangeSlice file — PPX auto-tags *Id fields
@schema
type command =
  | CreateItem({itemId: string, name: string})
  | RenameItem({itemId: string, newName: string})
```

The DCB tag:
1. Marks the field as a DCB query key
2. Automatically extracts tag values from commands at runtime
3. Enables efficient querying of relevant events from DcbEventLog

### Multiple `*Id` fields — partition key

When a variant has multiple `*Id` fields, use `@partitionTag` to mark which one is the partition key:

```rescript
@schema
type event =
  | DemandRecorded({
      @partitionTag productId: string,  // partition key
      orderId: string,                  // also tagged as DcbTag.string
    })
```

### Composite partition keys

When the partition key should be derived from **multiple fields joined in declaration order**, use `@compositePartitionTag`. Each annotated field is still individually queryable as a regular tag:

```rescript
@schema
type event =
  | PluginSynced({
      @compositePartitionTag environment: string,   // "/"  after (default)
      @compositePartitionTag platformName: string,  // "/"  after
      @compositePartitionTag pluginName: string,    // last — sep ignored
      version: string,
    })
// Partition key: e.g. "prod/acme-platform/billing"
```

Use `@compositePartitionTag(":")` to set a different separator after a field. Cannot be combined with `@partitionTag` on the same schema.

### Cross-Entity Queries with Tagged Arrays

When a command references multiple entities, use a `*Id: array<string>` field (singular name). Inside a `StateChangeSlice/` folder the PPX auto-applies `@s.matches(Reventless.DcbTag.string)` to the element type:

```rescript
@schema
type command =
  | PlaceOrder({
      orderId: string,                  // tagged automatically
      productId: array<string>,         // elements tagged automatically
    })
```

For a plural-named field (`productIds: array<string>`) the PPX strips the trailing `s` and tags the elements under key `productId`, so a multi-value field shares a tag key with the singular-named producers.

The runtime automatically detects tagged array fields and builds multi-clause OR queries — one clause per scalar tag, one per array element. This fetches events for all referenced entities into the same state, enabling cross-entity validation at command time.

**Key rule:** name the array field to match the tag key on the referenced events (e.g., command field `productId` matches the `productId` tag on `CatalogProductSynced` events).

## Best Practices

### 1. Keep Decision Models Focused

```rescript
// Good: Focused on specific domain concern
type state = {
  active: bool,
  lastActivity: option<Js.Date.t>,
}

// Avoid: Bloated models trying to handle everything
type state = {
  // ... 50+ fields for unrelated concerns
}
```

### 2. Match `consumedEvent` Exhaustively in `evolve`

```rescript
// consumedEvent lists exactly the variants this slice reads,
// so evolve matches them all — no catch-all needed.
let evolve = (state, event) =>
  switch event {
  | KnownEvent1 => state // handle
  | KnownEvent2 => state // handle
  }
```

### 3. Idempotent Commands

Design commands to be idempotent when possible. A command that produces no state change should return `Ok([])`, not an error — commands may be retried under at-least-once delivery:

```rescript
let decide = (state, command) =>
  switch command {
  | SetName({id, name}) =>
    if name == state.name {
      Ok([]) // idempotent — name unchanged, emit nothing
    } else {
      Ok([NameSet({id, name})])
    }
  }
```

### 4. Tag Only What's Needed

DCB tags are auto-applied to `*Id` fields inside `StateChangeSlice/` folders. For a payload field that happens to end in `Id` but is **not** a query key, suppress tagging with `@noDcbTag`:

```rescript
// Good: *Id fields are tagged automatically; suppress the ones that are payload only
@schema
type command = CreateItem({
  itemId: string,            // auto-tagged for entity lookup
  @noDcbTag externalId: string,  // payload data, not a DCB query key
})
```

## Comparison with Aggregate

| Aspect | Aggregate | StateChangeSlice |
|--------|-----------|------------------|
| **Ownership** | Own event log | Shared event log |
| **Isolation** | Separate Lambda | Shared Lambda |
| **Command Type** | Strongly typed | Schema-based routing |
| **Concurrency** | Optimistic (sequenceNr) | Optimistic (position) |
| **Use Case** | Entity boundaries | Cross-entity consistency |

See [DCB Plugin Usage Documentation](../dcb-slices.md) for more details on when to use StateChangeSlice vs Aggregate.

## Related Topics

- [StateChangeSlice Component Reference](../components/statechangeslice.md)
- [DCB Plugin Architecture](../dcb-slices.md)
- [DcbEventLog](/framework/runtime-components/dcbeventlog)
- [CommandTopic](/framework/runtime-components/commandtopic)
