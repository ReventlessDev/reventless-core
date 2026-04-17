---
title: StateViewSlice Usage
date: 2026-02-18
draft: false
---

This guide covers how to use StateViewSlice in your Reventless application. For the component reference, see [StateViewSlice](../components/stateviewslice.md).

## Usage Pattern

### Defining a StateViewSlice Spec

```rescript title="ItemView_Slice.res"
module ItemViewSpec = {
  let name = "ItemView"

  module DcbEventLogSpec = MyDcbEventLogSpec

  @schema
  type event = 
    | ItemCreated({itemId: string, name: string})
    | ItemRenamed({itemId: string, newName: string})
    | ItemDeleted({itemId: string})

  @schema
  type state = {
    name: string,
    createdAt: float,
    updatedAt: float,
  }

  // Projection function: transforms events into projection actions
  let project = (currentState, event) =>
    switch event {
    | ItemCreated({itemId, name}) =>
      let now = Js.Date.now()
      [Projection.Create(itemId, {name, createdAt: now, updatedAt: now})]
      
    | ItemRenamed({itemId, newName}) =>
      let now = Js.Date.now()
      [Projection.Update(itemId, state => {...state, name: newName, updatedAt: now})]
      
    | ItemDeleted({itemId}) =>
      [Projection.Delete(itemId)]
    }
}
```

### Building the Slice

```rescript title="Creating the slice component"
module ItemViewSlice = StateViewSlice_Builder.Make(ItemViewSpec)

let sliceComponent = ItemViewSlice.make(
  ~dcbEventLog,
  ~opts=pulumiOptions,
)
```

The [`StateViewSlice_Builder.Make`](../rescript-syntax.md#functors) [module function](../rescript-syntax.md#functors):
1. Creates a callback module with projection logic
2. Sets up event handling from DcbEventLog
3. Connects to QueryDb for state storage

## Projection Pattern

The projection function is the core of StateViewSlice - it transforms events into state changes:

```rescript
// Example: Inventory projection
type state = {
  quantity: int,
  reserved: int,
  available: int,
}

let project = (currentState, event) =>
  switch event {
  | StockReceived({itemId, qty}) =>
    // Create new state if doesn't exist
    [Projection.UpdateWithDefault(itemId, {quantity: 0, reserved: 0, available: 0}, 
      state => {...state, quantity: state.quantity + qty, available: state.available + qty}
    )]
    
  | ItemReserved({itemId, qty}) =>
    [Projection.Update(itemId, state => {
      ...state,
      reserved: state.reserved + qty,
      available: state.available - qty,
    })]
    
  | ReservationReleased({itemId, qty}) =>
    [Projection.Update(itemId, state => {
      ...state,
      reserved: state.reserved - qty,
      available: state.available + qty,
    })]
    
  | StockAdjusted({itemId, newQty}) =>
    // Set absolute value
    [Projection.Set(itemId, state => {...state, quantity: newQty})]
  }
```

### Available Projection Actions

| Action | Description | Use Case |
|--------|-------------|----------|
| `Create(id, state)` | Create new state | New entities |
| `Set(id, state)` | Set/replace state | Full state replacement |
| `Update(id, updateFn)` | Update existing state | Modifications to existing entities |
| `UpdateWithDefault(id, default, updateFn)` | Update with default | Handle both new and existing |
| `Delete(id)` | Delete state | Entity removal |
| `CreateMany(states)` | Batch create | Initial population |

## Integration with Plugin

StateViewSlice is integrated into the Plugin via the `DcbSpec`:

```rescript
module MyDcbSpec = {
  @schema
  type event = 
    | ItemCreated({itemId: string, name: string})
    | ItemRenamed({itemId: string, newName: string})
    | ItemDeleted({itemId: string})
    | StockReceived({itemId: string, qty: int})
    | ItemReserved({itemId: string, qty: int})

  let stateChangeSlices = [
    module(CreateItemSlice: StateChangeSlice.T with type dcbEvent = event),
    module(RenameItemSlice: StateChangeSlice.T with type dcbEvent = event),
    module(DeleteItemSlice: StateChangeSlice.T with type dcbEvent = event),
  ]
  
  let stateViewSlices = [
    module(ItemViewSlice: StateViewSlice.T with type dcbEvent = event),
    module(InventoryViewSlice: StateViewSlice.T with type dcbEvent = event),
  ]
}

// Inside the plugin's Make functor:
let make = () =>
  Platform.Plugin.make(
    ~name="MyPlugin",
    ~heartbeatInterval=300,
    ~stateChangeSlices=[module(CreateItemSlice), module(RenameItemSlice)],
    ~stateViewSlices=[module(InventoryViewSlice)],
  )
```

### Plugin Outputs

```rescript
type outputs = {
  // ...existing outputs...
  dcbEventLog: Pulumi.Output.t<option<DcbEventLog.outputs>>,
  stateChangeSlices: Pulumi.Output.t<dict<StateChangeSlice.outputs>>,
  stateViewSlices: Pulumi.Output.t<dict<StateViewSlice.outputs>>,
}
```

- `dcbEventLog`: Contains the shared event log outputs
- `stateChangeSlices`: Dictionary of command-processing slices
- `stateViewSlices`: Dictionary of projection slices with their QueryDb outputs

### Accessing QueryDb from StateViewSlices

```rescript
// Access QueryDb from plugin outputs
let itemViewOutputs = pluginOutputs.stateViewSlices->Dict.get("ItemView")

// The QueryDb outputs can be used for:
// - Building resolvers
// - Connecting to other components
// - Getting the table name for direct queries
let queryDbOutputs = itemViewOutputs->Option.map(outputs => outputs.queryDb)
```

## Best Practices

### 1. Use UpdateWithDefault for Optional Creation

```rescript
// Good: Handles both new and existing entities
let project = (currentState, event) =>
  switch event {
  | ItemCreated({itemId, data}) =>
    [Projection.UpdateWithDefault(itemId, {count: 0}, state => 
      {...state, /* update logic */}
    )]
  }

// Avoid: Will fail if entity doesn't exist
let project = (currentState, event) =>
  switch event {
  | ItemCreated({itemId, data}) =>
    [Projection.Update(itemId, state => {/* update logic */})]  // Will fail!
  }
```

### 2. Keep Projections Idempotent

```rescript
// Good: Idempotent - running multiple times produces same result
let project = (currentState, event) =>
  switch event {
  | QuantityAdjusted({itemId, delta}) =>
    [Projection.Update(itemId, state => {...state, qty: state.qty + delta})]
  }

// Be careful: Non-idempotent operations may cause issues on replay
```

### 3. Denormalize for Read Efficiency

```rescript
// Good: Denormalized read model
type state = {
  // Store computed values for fast reads
  itemName: string,
  categoryName: string,  // Denormalized from Category aggregate
  totalQuantity: int,     // Computed aggregate
}

// Avoid: requiring joins at read time
type state = {
  itemId: string,
  // This would require lookups at read time...
}
```

### 4. Handle All Event Types

```rescript
// Always include catch-all or explicit handling for all events
let project = (currentState, event) =>
  switch event {
  | KnownEvent1 => // handle
  | KnownEvent2 => // handle
  | _ => [Projection.Ignore]  // Explicitly ignore unknown events
  }
```

## Complete Example

Here's a complete example combining StateChangeSlice and StateViewSlice:

```rescript title="DCB Spec Module"
// Shared event types
module MyDcbEvents = {
  @schema
  type event =
    | ItemCreated({itemId: string, name: string, category: string})
    | ItemRenamed({itemId: string, newName: string})
    | QuantityAdjusted({itemId: string, delta: int})
    | ItemDeleted({itemId: string})
}

// StateChangeSlice: Handles commands
module CreateItemSliceSpec = {
  let name = "CreateItem"
  module DcbEventLogSpec = MyDcbEvents
  
  @schema
  type command = CreateItem({
    itemId: @s.matches(DcbTag.string) string,
    name: string,
    category: string,
  })
  
  @schema
  type error = ItemAlreadyExists
  
  type decisionModel = {exists: bool}
  let initialDecisionModel = {exists: false}
  
  let reduce = (model, event) =>
    switch event {
    | MyDcbEvents.ItemCreated(_) => {exists: true}
    | _ => model
    }
  
  let decide = (model, command) =>
    if model.exists {
      Error(ItemAlreadyExists)
    } else {
      Ok([MyDcbEvents.ItemCreated({
        itemId: command.itemId,
        name: command.name,
        category: command.category,
      })])
    }
}

// StateViewSlice: Projects to read model
module ItemReadViewSpec = {
  let name = "ItemReadView"
  module DcbEventLogSpec = MyDcbEvents
  
  @schema
  type event = MyDcbEvents.event
  
  @schema
  type state = {
    name: string,
    category: string,
    quantity: int,
    createdAt: float,
  }
  
  let project = (currentState, event) =>
    switch event {
    | ItemCreated({itemId, name, category}) =>
      let now = Js.Date.now()
      [Projection.Create(itemId, {name, category, quantity: 0, createdAt: now})]
      
    | ItemRenamed({itemId, newName}) =>
      [Projection.Update(itemId, state => {...state, name: newName})]
      
    | QuantityAdjusted({itemId, delta}) =>
      [Projection.Update(itemId, state => {...state, quantity: state.quantity + delta})]
      
    | ItemDeleted({itemId}) =>
      [Projection.Delete(itemId)]
    }
}

// Plugin DCB Spec
module MyDcbSpec = {
  type event = MyDcbEvents.event
  
  let stateChangeSlices = [
    module(StateChangeSlice_Builder.Make(CreateItemSliceSpec): 
      StateChangeSlice.T with type dcbEvent = event),
  ]
  
  let stateViewSlices = [
    module(StateViewSlice_Builder.Make(ItemReadViewSpec):
      StateViewSlice.T with type dcbEvent = event),
  ]
}
```

## Related Topics

- [StateViewSlice Component Reference](../components/stateviewslice.md)
- [StateChangeSlice Usage](./statechangeslice-usage.md)
- [DCB Plugin Architecture](../dcb-slices.md)
- [DcbEventLog](../components/dcbeventlog.md)
- [QueryDb](../components/querydb.md)
- [ReadModel](../components/readmodel.md)
