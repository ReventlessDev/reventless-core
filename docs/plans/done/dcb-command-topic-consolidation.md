# DCB Command Topic Consolidation Plan

## Current State Analysis

### Problem Statement
Currently, each `StateChangeSlice` creates its own `CommandTopic`, resulting in:
- Multiple command topics per plugin (one per state change slice)
- Each state change slice only receives commands meant for its specific command type
- Inefficient resource usage and complexity

### Current Architecture

#### Plugin.DcbSpec (packages/reventless/src/components/Plugin/Plugin.res)
```rescript
module type DcbSpec = {
  @schema
  type event

  @schema
  type command  // Plugin-wide command type (union of all slice commands)

  let stateChangeSlices: array<module(StateChangeSlice.T with type dcbEvent = event)>
}
```

#### StateChangeSlice.T (packages/reventless/src/components/StateChangeSlice/StateChangeSlice.res)
```rescript
module type T = {
  type dcbEvent
  module Spec: Spec  // Each slice has its own command type in Spec

  let make: (
    ~dcbEventLog: DcbEventLog.component<DcbEventLog.operations<dcbEvent>>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
```

#### StateChangeSlice.Spec
```rescript
module type Spec = {
  let name: string
  module DcbEventLogSpec: DcbEventLog.Spec
  @schema
  type command  // Each slice defines its own command type
  @schema
  type error
  type decisionModel
  let initialDecisionModel: decisionModel
  let reduce: (decisionModel, DcbEventLogSpec.event) => decisionModel
  let decide: (decisionModel, command) => result<array<DcbEventLogSpec.event>, error>
  let queryEventTypes: array<string>
}
```

#### StateChangeSlice_Builder.Make (packages/reventless/src/components/StateChangeSlice/StateChangeSlice_Builder.res)
- Creates its own `CommandTopic` via `SpecificCommandTopic.make()`
- Creates a handler via `SpecificCommandTopic.makeHandler()`
- Each slice has its own command topic with its own command type

#### Plugin_Builder (packages/reventless/src/components/Plugin/Plugin_Builder.res)
- Creates `DcbEventLog` once
- Iterates over `DcbSpec.stateChangeSlices` and calls each `StateChangeSlice.make(~dcbEventLog, ~opts)`
- Each StateChangeSlice creates its own CommandTopic

## Proposed Changes

### Step 1: Create Plugin-Wide DCB Command Topic

Modify `Plugin_Builder.Make` to:
1. Create ONE `DcbCommandTopic` using `DcbSpec.command` type
2. Pass this shared command topic to all state change slices

### Step 2: Modify StateChangeSlice.T Interface

Update `StateChangeSlice.T` to accept the shared command topic:
```rescript
module type T = {
  type dcbEvent
  type dcbCommand  // Add this type
  module Spec: Spec

  let make: (
    ~dcbEventLog: DcbEventLog.component<DcbEventLog.operations<dcbEvent>>,
    ~dcbCommandTopic: CommandTopic.component<...>,  // Add this parameter
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
```

### Step 3: Modify StateChangeSlice_Builder.Make

- Remove internal CommandTopic creation
- Accept the shared command topic as parameter
- Register handler with the shared command topic
- Each slice receives ALL commands (filtering will be added in next step)

### Step 4: Update StateChangeSlice.outputs

Remove `commandTopic` from outputs since it's now shared at plugin level:
```rescript
type outputs = {
  resources: array<ReventlessSpec.Adapter.resource>,
  // commandTopic removed - now at plugin level
}
```

### Step 5: Update Plugin.outputs

Add `dcbCommandTopic` to plugin outputs:
```rescript
type outputs = {
  // ... existing fields
  dcbCommandTopic: Pulumi.Output.t<CommandTopic.outputs>,  // Add this
  stateChangeSlices: Pulumi.Output.t<dict<StateChangeSlice.outputs>>,
}
```

## Implementation Order

1. **StateChangeSlice.res** - Update type definitions
2. **StateChangeSlice_Builder.res** - Modify to accept shared command topic
3. **Plugin.res** - Add dcbCommandTopic to outputs
4. **Plugin_Builder.res** - Create shared DCB command topic and pass to slices
5. **Plugin_Helpers.res** - Update pureOutputs type if needed

## Key Files to Modify

| File | Changes |
|------|---------|
| `packages/reventless/src/components/StateChangeSlice/StateChangeSlice.res` | Update T interface, remove commandTopic from outputs |
| `packages/reventless/src/components/StateChangeSlice/StateChangeSlice_Builder.res` | Accept shared command topic, remove internal topic creation |
| `packages/reventless/src/components/Plugin/Plugin.res` | Add dcbCommandTopic to outputs |
| `packages/reventless/src/components/Plugin/Plugin_Builder.res` | Create shared DCB command topic, pass to slices |
| `packages/reventless/src/components/Plugin/Plugin_Helpers.res` | Update pureOutputs type |

## Future Step (Not in This Task)

After this consolidation, the next step will be to:
- Add command filtering/routing so each state change slice only receives relevant commands
- This could be done via:
  - A routing function in DcbSpec
  - Command type discrimination
  - Tag-based routing

## Technical Considerations

### Command Type Compatibility
- `DcbSpec.command` is the union type of all slice commands
- Each `StateChangeSlice.Spec.command` is a subset of this union
- The callback handler needs to decode the full command type and filter to its specific type

### Handler Registration
- Multiple handlers will be registered to the same command topic
- Each handler will receive ALL commands
- Each handler should filter commands it can process

### Runtime Builder
- Need to add `forDcbCommandTopic` to `PluginRuntime_Builder.T`
- Similar to how `forPluginEventCollector` and `forPluginHeartbeat` work