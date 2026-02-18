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

  type decisionModel = {exists: bool}
  let initialDecisionModel = {exists: false}

  let reduce = (model, event) =>
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

The `StateChangeSlice_Builder.Make` functor:
1. Creates a callback module with decision logic
2. Sets up JSON command decoding
3. Registers the handler in the global CommandTopic registry

## Decision Model Pattern

The decision model is the key abstraction that makes StateChangeSlice powerful:

```rescript
// Example: Inventory management
type decisionModel = {
  quantity: int,
  reserved: int,
  available: int,
}

let initialDecisionModel = {quantity: 0, reserved: 0, available: 0}

let reduce = (model, event) =>
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

StateChangeSlice is integrated into the Plugin via the `DcbSpec`:

```rescript
module MyDcbSpec = {
  @schema
  type event = 
    | ItemCreated({itemId: string, name: string})
    | ItemRenamed({itemId: string, newName: string})
    | ItemDeleted({itemId: string})

  let stateChangeSlices = [
    module(CreateItemSlice: StateChangeSlice.T with type dcbEvent = event),
    module(RenameItemSlice: StateChangeSlice.T with type dcbEvent = event),
    module(DeleteItemSlice: StateChangeSlice.T with type dcbEvent = event),
  ]
}

let plugin = MyPlugin.make(
  ~name="my-plugin",
  ~version="1.0.0",
  ~heartbeatInterval=300,
  ~scheduler,
  ~dcbSpec=module(MyDcbSpec),
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

StateChangeSlice uses DCB tags for efficient event queries. Tags are extracted from command fields marked with `@s.matches(DcbTag.string)`:

```rescript
@schema
type command = 
  | CreateItem({itemId: @s.matches(DcbTag.string) string, name: string})
  | RenameItem({itemId: @s.matches(DcbTag.string) string, newName: string})
```

The `@s.matches(DcbTag.string)` annotation:
1. Marks the field as a DCB tag
2. Automatically extracts tag values from commands
3. Enables efficient querying of relevant events from DcbEventLog

## Best Practices

### 1. Keep Decision Models Focused

```rescript
// Good: Focused on specific domain concern
type decisionModel = {
  active: bool,
  lastActivity: option<Js.Date.t>,
}

// Avoid: Bloated models trying to handle everything
type decisionModel = {
  // ... 50+ fields for unrelated concerns
}
```

### 2. Use Catch-All in Reduce

```rescript
// Always include catch-all for future event types
let reduce = (model, event) =>
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

See [DCB Plugin Usage Documentation](../../docs/dcb-plugin-usage.md) for more details on when to use StateChangeSlice vs Aggregate.

## Related Topics

- [StateChangeSlice Component Reference](../components/statechangeslice.md)
- [DCB Plugin Architecture](../../docs/dcb-plugin-usage.md)
- [DcbEventLog](../components/dcbeventlog.md)
- [CommandTopic](../components/commandtopic.md)
