# DCB Plugin Support

The Plugin component supports an optional DCB (Dynamic Consistency Boundary) event log that can be shared across multiple state change slices.

## Overview

When you provide a DCB spec to the plugin:
1. The plugin creates a single DCB event log using the spec and the plugin's name
2. All state change slices receive this shared DCB event log
3. State change slices can read and append events to the same event log

## Plugin.DcbSpec Module Type

A `Plugin.DcbSpec` bundles the plugin-wide event/command schema together with the state change slices that operate on it. This ensures compile-time type safety between the event log and all handlers.

```rescript
module type DcbSpec = {
  @schema
  type event

  @schema
  type command

  let stateChangeSlices: array<module(StateChangeSlice.T with type dcbEvent = event)>
}
```

The `with type dcbEvent = event` constraint guarantees that every state change slice's event type matches the DcbSpec's event type at compile time.

## Usage

### 1. Define your DCB event log spec

```rescript
module MyDcbEventLogSpec = {
  let name = "MyPlugin"

  @schema
  type event =
    | ItemCreated({itemId: @s.matches(DcbTag.string) string, name: string})
    | ItemUpdated({itemId: @s.matches(DcbTag.string) string, newName: string})
}
```

### 2. Define state change slice specs

Each state change slice spec references the shared DcbEventLog spec:

```rescript
module CreateItemSpec = {
  let name = "CreateItemHandler"

  module DcbEventLogSpec = MyDcbEventLogSpec

  @schema
  type command = CreateItem({itemId: string, name: string})

  @schema
  type error = ItemAlreadyExists

  type decisionModel = {exists: bool}
  let initialDecisionModel = {exists: false}

  let reduce = (model, event) =>
    switch event {
    | MyDcbEventLogSpec.ItemCreated(_) => {exists: true}
    | _ => model
    }

  let decide = (model, command) =>
    switch command {
    | CreateItem({itemId, name}) =>
      if model.exists {
        Error(ItemAlreadyExists)
      } else {
        Ok([MyDcbEventLogSpec.ItemCreated({itemId, name})])
      }
    }

  let queryEventTypes = ["ItemCreated"]
}
```

### 3. Build state change slices

`StateChangeSlice_Builder.Make` takes the spec and a command topic channel adapter. The DcbEventLog is **not** provided here — it will be injected by the plugin at deploy time.

```rescript
module CreateItemHandler = StateChangeSlice_Builder.Make(
  CreateItemSpec,
  CommandTopic_SqsFifoAdapter.Channel,
)

module UpdateItemHandler = StateChangeSlice_Builder.Make(
  UpdateItemSpec,
  CommandTopic_SqsFifoAdapter.Channel,
)
```

### 4. Bundle into a DcbSpec

```rescript
module MyPluginDcbSpec = {
  @schema
  type event = MyDcbEventLogSpec.event

  @schema
  type command =
    | CreateItem({itemId: string, name: string})
    | UpdateItem({itemId: string, newName: string})

  let stateChangeSlices = [
    module(CreateItemHandler: StateChangeSlice.T with type dcbEvent = event),
    module(UpdateItemHandler: StateChangeSlice.T with type dcbEvent = event),
  ]
}
```

### 5. Create the plugin

```rescript
let plugin = MyPlugin.make(
  ~name="my-plugin",
  ~version="1.0.0",
  ~heartbeatInterval=300,
  ~scheduler,
  ~dcbSpec=module(MyPluginDcbSpec),
)
```

## Plugin Outputs

The plugin outputs include:

```rescript
type outputs = {
  // ... existing outputs ...
  dcbEventLog: Pulumi.Output.t<option<DcbEventLog.outputs>>,
  stateChangeSlices: Pulumi.Output.t<dict<StateChangeSlice.outputs>>,
}
```

- `dcbEventLog`: `Some(outputs)` if DCB was provided, `None` otherwise
- `stateChangeSlices`: Dictionary of state change slice outputs, keyed by handler name (from `Spec.name`)

## Key Features

- **Automatic Naming**: The DCB event log automatically uses the plugin name
- **Shared State**: All state change slices operate on the same event log
- **Compile-Time Type Safety**: The `with type dcbEvent = event` constraint ensures event types are consistent across the DcbEventLog and all StateChangeSlices — no runtime casts needed
- **Dynamic Querying**: Use DCB tags to query events across different entity types
- **Flexible Boundaries**: Define consistency boundaries at the plugin level rather than aggregate level
