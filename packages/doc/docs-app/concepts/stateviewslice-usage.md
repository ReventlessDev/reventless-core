---
title: StateViewSlice Usage
date: 2026-02-18
draft: false
---

This guide covers how to use StateViewSlice in your Reventless application. For the component reference, see [StateViewSlice](../components/stateviewslice.md).

## Usage Pattern

A StateViewSlice is **two files** in a `StateViewSlice/` (or `StateViewSliceStream/`) folder: a spec file (`<Name>.res`) declaring the events it consumes and the read-model `state`, and a projection file (`<Name>_Projection.res`) holding the projection logic. The plugin generator wires them together.

### Defining the Spec

The spec file carries `@@reventless.spec`. Because it lives in a view-slice folder, the PPX also auto-injects `let config`, `let subIdConfig`, and `open Reventless.Projection`. A view slice declares its own `consumedEvent` (the events it reads) and `state` (the shape of each read-model row).

```rescript title="ItemView.res"
@@reventless.spec

@schema
type consumedEvent =
  | ItemCreated({itemId: string, name: string})
  | ItemRenamed({itemId: string, name: string})
  | ItemDeleted({itemId: string})

@schema
type state = {
  itemId: string,
  name: string,
}
```

### Defining the Projection

The projection file carries `@@reventless.projection`. `project` takes **one argument** — the event — and returns an array of projection actions. `Set`/`Update`/`UpdateWithDefault`/`Delete` are in scope without a `Projection.` prefix (the PPX opens `Reventless.Projection`).

```rescript title="ItemView_Projection.res"
@@reventless.projection

let project = event =>
  switch event {
  | ItemCreated({itemId, name}) => [Set(itemId, {itemId, name})]
  | ItemRenamed({itemId, name}) => [Update(itemId, state => {...state, name})]
  | ItemDeleted({itemId}) => [Delete(itemId)]
  }
```

### Wiring the Slice

Wiring is generated into `Plugin.res` as a two-argument functor call — spec first, projection second:

```rescript title="Plugin.res (generated)"
module ItemViewSlice = Platform.StateViewSliceStream.Make(ItemView, ItemView_Projection)
```

The generator:
1. Pairs the spec with its projection via `Platform.StateViewSliceStream.Make`
2. Sets up event handling from the shared event log
3. Provisions the QueryDb for state storage

## Projection Pattern

The projection function is the core of StateViewSlice — it transforms each consumed event into state changes. `Set` creates or replaces a row; `Update` transforms an existing row; `UpdateWithDefault` handles both:

```rescript title="Inventory_Projection.res"
let project = event =>
  switch event {
  | StockReceived({itemId, qty}) =>
    // Create with a default if the row does not exist yet
    [
      UpdateWithDefault(
        itemId,
        {quantity: 0, reserved: 0, available: 0},
        state => {...state, quantity: state.quantity + qty, available: state.available + qty},
      ),
    ]

  | ItemReserved({itemId, qty}) => [
      Update(itemId, state => {
        ...state,
        reserved: state.reserved + qty,
        available: state.available - qty,
      }),
    ]

  | ReservationReleased({itemId, qty}) => [
      Update(itemId, state => {
        ...state,
        reserved: state.reserved - qty,
        available: state.available + qty,
      }),
    ]

  | StockAdjusted({itemId, newQty}) =>
    // Set the absolute value
    [Update(itemId, state => {...state, quantity: newQty})]
  }
```

### Available Projection Actions

In scope inside a `*_Projection.res` file (no `Projection.` prefix needed):

| Action | Description | Use Case |
|--------|-------------|----------|
| `Set(id, state)` | Create or replace a row | New row or full replacement |
| `Update(id, updateFn)` | Transform an existing row | Modifications to existing rows |
| `UpdateWithDefault(id, default, updateFn)` | Update, creating with `default` if absent | Handle both new and existing |
| `Delete(id)` | Delete a row | Entity removal |
| `Ignore` (or `[]`) | No state change | Events that don't affect this view |

## Integration with Plugin

StateViewSlices are wired into the generated `Plugin.res` and passed to `Platform.Plugin.make` via the `~stateViewSlices` array:

```rescript title="Plugin.res (generated)"
module ItemViewSlice = Platform.StateViewSliceStream.Make(ItemView, ItemView_Projection)
module InventoryViewSlice = Platform.StateViewSliceStream.Make(InventoryView, InventoryView_Projection)

// Inside the plugin's Make functor:
let make = () =>
  Platform.Plugin.make(
    ~name="MyPlugin",
    ~heartbeatInterval=5,
    ~stateChangeSlices=[module(CreateItemSlice), module(RenameItemSlice)],
    ~stateViewSlices=[module(ItemViewSlice), module(InventoryViewSlice)],
    // ...other component arrays...
  )
```

## Best Practices

### 1. Use UpdateWithDefault for Optional Creation

```rescript
// Good: handles both new and existing rows
let project = event =>
  switch event {
  | ItemAdjusted({itemId, delta}) => [
      UpdateWithDefault(itemId, {count: 0}, state => {...state, count: state.count + delta}),
    ]
  }

// Avoid: Update on a row that may not exist yet is a no-op
let project = event =>
  switch event {
  | ItemAdjusted({itemId, delta}) => [Update(itemId, state => {...state, count: state.count + delta})]
  }
```

### 2. Keep Projections Idempotent

```rescript
// Good: setting an absolute value is idempotent on replay
let project = event =>
  switch event {
  | QuantitySet({itemId, qty}) => [Update(itemId, state => {...state, qty})]
  }

// Be careful: relative deltas can double-count if events are re-delivered
```

### 3. Denormalize for Read Efficiency

```rescript
// Good: denormalized read model
type state = {
  // Store computed values for fast reads
  itemName: string,
  categoryName: string,  // Denormalized from Category aggregate
  totalQuantity: int,    // Pre-aggregated
}

// Avoid: requiring joins at read time
type state = {
  itemId: string,
  // This would require lookups at read time...
}
```

### 4. Match `consumedEvent` Exhaustively

```rescript
// consumedEvent lists exactly the events this view reads, so the switch is exhaustive.
// For an event that should not change state, return [] (or [Ignore]).
let project = event =>
  switch event {
  | KnownEvent1({id}) => [Update(id, state => state)]
  | KnownEvent2({id}) => [Delete(id)]
  | NoteAdded(_) => [] // no state change
  }
```

## Complete Example

Here's a complete example combining StateChangeSlice and StateViewSlice on the same DCB event log. Each component is its own pair of files; the slice's `consumedEvent`/`event` types are local — there is no shared DCB spec module.

```rescript title="CreateItem.res — StateChangeSlice spec"
@@reventless.spec

@schema
type consumedEvent =
  | ItemCreated

@schema
type command =
  | CreateItem({itemId: string, name: string, category: string})

@schema
type error = ItemAlreadyExists

@schema
type event =
  | ItemCreated({itemId: string, name: string, category: string})
```

```rescript title="CreateItem_Behavior.res — StateChangeSlice behavior"
@@reventless.behavior

type state = {exists: bool}
let initialState = {exists: false}

let evolve = (_state, event) =>
  switch event {
  | ItemCreated => {exists: true}
  }

let decide = (state, command) =>
  switch command {
  | CreateItem({itemId, name, category}) =>
    if state.exists {
      Error(ItemAlreadyExists)
    } else {
      Ok([ItemCreated({itemId, name, category})])
    }
  }
```

```rescript title="ItemView.res — StateViewSlice spec"
@@reventless.spec

@schema
type consumedEvent =
  | ItemCreated({itemId: string, name: string, category: string})
  | ItemRenamed({itemId: string, name: string})
  | ItemDeleted({itemId: string})

@schema
type state = {
  itemId: string,
  name: string,
  category: string,
}
```

```rescript title="ItemView_Projection.res — StateViewSlice projection"
@@reventless.projection

let project = event =>
  switch event {
  | ItemCreated({itemId, name, category}) => [Set(itemId, {itemId, name, category})]
  | ItemRenamed({itemId, name}) => [Update(itemId, state => {...state, name})]
  | ItemDeleted({itemId}) => [Delete(itemId)]
  }
```

```rescript title="Plugin.res (generated) — wiring"
module CreateItemSlice = Platform.StateChangeSlice.Make(CreateItem, CreateItem_Behavior)
module ItemViewSlice = Platform.StateViewSliceStream.Make(ItemView, ItemView_Projection)
```

## Related Topics

- [StateViewSlice Component Reference](../components/stateviewslice.md)
- [StateChangeSlice Usage](./statechangeslice-usage.md)
- [DCB Plugin Architecture](../dcb-slices.md)
- [DcbEventLog](../components/dcbeventlog.md)
- [QueryDb](../components/querydb.md)
- [ReadModel](../components/readmodel.md)
