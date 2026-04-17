---
title: StateChangeSlice Usage
date: 2026-02-17
draft: false
---

This guide covers how to use StateChangeSlice in your Reventless application. For the component reference, see [StateChangeSlice](../components/statechangeslice.md).

## Usage Pattern

### Defining a StateChangeSlice Spec

```rescript title="CreateItem_Slice.res"
module CreateItemSpec = {
  let name = "CreateItem"

  module DcbEventLogSpec = MyDcbEventLogSpec

  @schema
  type command = CreateItem({
    itemId: @s.matches(DcbTag.string) string,
    name: string,
  })

  @schema
  type error = 
    | ItemAlreadyExists
    | InvalidName

  type state = {exists: bool}
  let initialState = {exists: false}

  let evolve = (state, event) =>
    switch event {
    | DcbEventLogSpec.ItemCreated(_) => {exists: true}
    | _ => model
    }

  let decide = (model, command) =>
    switch command {
    | CreateItem({itemId, name}) =>
      if name->String.length < 1 {
        Error(InvalidName)
      } else if model.exists {
        Error(ItemAlreadyExists)
      } else {
        Ok([DcbEventLogSpec.ItemCreated({itemId, name})])
      }
    }
}
```

### Building the Slice

```rescript title="Creating the slice component"
module CreateItemSlice = StateChangeSlice_Builder.Make(CreateItemSpec)

let sliceComponent = CreateItemSlice.make(
  ~dcbEventLog,
  ~publishJsons,
  ~opts=pulumiOptions,
)
```

The [`StateChangeSlice_Builder.Make`](../rescript-syntax.md#functors) [module function](../rescript-syntax.md#functors):
1. Creates a callback module with decision logic
2. Sets up JSON command decoding
3. Registers the handler in the global CommandTopic registry

## Decision Model Pattern

The decision model is the key abstraction that makes StateChangeSlice powerful:

```rescript
// Example: Inventory management
type state = {
  quantity: int,
  reserved: int,
  available: int,
}

let initialState = {quantity: 0, reserved: 0, available: 0}

let evolve = (state, event) =>
  switch event {
  | StockReceived({qty}) => {
      ...model,
      quantity: model.quantity + qty,
      available: model.available + qty,
    }
  | ItemReserved({qty}) => {
      ...model,
      reserved: model.reserved + qty,
      available: model.available - qty,
    }
  | ReservationReleased({qty}) => {
      ...model,
      reserved: model.reserved - qty,
      available: model.available + qty,
    }
  | _ => model  // Catch-all for unrelated events
  }

let decide = (model, command) =>
  switch command {
  | ReserveItem({itemId, qty}) =>
    if qty > model.available {
      Error(InsufficientStock(model.available))
    } else {
      Ok([ItemReserved({itemId, qty})])
    }
  }
```

## Integration with Plugin

Slices are passed directly to `Plugin.make` — no `DcbSpec` wrapper needed:

```rescript
// Inside the plugin's Make functor:
let make = () =>
  Platform.Plugin.make(
    ~name="MyPlugin",
    ~heartbeatInterval=300,
    ~stateChangeSlices=[
      module(CreateItemSlice),
      module(RenameItemSlice),
      module(DeleteItemSlice),
    ],
  )
```

### Plugin Outputs

```rescript
type outputs = {
  // ...existing outputs...
  dcbEventLog: Pulumi.Output.t<option<DcbEventLog.outputs>>,
  stateChangeSlices: Pulumi.Output.t<dict<StateChangeSlice.outputs>>,
}
```

- `dcbEventLog`: Contains the shared event log outputs (DynamoDB table, SNS topic)
- `stateChangeSlices`: Dictionary keyed by slice name, containing resources for each slice

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

When a command references multiple entities, use a `*Id: array<string>` field (singular name). The PPX auto-injects `@s.matches(DcbTag.string)` on the element type:

```rescript
@schema
type command =
  | PlaceOrder({
      orderId: string,                  // tagged: DcbTag.string
      productId: array<string>,         // elements tagged: DcbTag.string
    })
```

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

### 2. Use Catch-All in Reduce

```rescript
// Always include catch-all for future event types
let evolve = (state, event) =>
  switch event {
  | KnownEvent1 => // handle
  | KnownEvent2 => // handle
  | _ => model  // Pass through unknown events
  }
```

### 3. Idempotent Commands

Design commands to be idempotent when possible:

```rescript
let decide = (model, command) =>
  switch command {
  | SetName({id, name}) =>
    // Idempotent: setting same name twice is fine
    Ok([NameSet({id, name})])
  }
```

### 4. Tag Only What's Needed

```rescript
// Good: Tag by entity ID for entity-scoped queries
type command = CreateItem({
  itemId: @s.matches(DcbTag.string) string,  // Tag for entity lookup
  metadata: string,  // Not tagged - not needed for queries
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
- [DcbEventLog](../components/dcbeventlog.md)
- [CommandTopic](../components/commandtopic.md)
