---
title: Component Structure Pattern
---

## Overview

Reventless follows a standardized **Component Structure Pattern** across all framework components. This pattern ensures consistency, type safety, and clear separation of concerns while maintaining provider independence and testability.

The pattern uses a multi-file organization where each file has a specific responsibility, from type definitions to runtime operations.

## The Multi-File Pattern

Components use 2 required files and up to 3 optional files based on their needs:

### Core Files (Required)

#### Component.res - Interface & Types
- **Purpose**: Define the component's public interface and type contracts
- **Contains**: Type definitions, module types, helper functions
- **Exports**: `outputs`, `operations`, `component` types, and module type `T`

#### Component_Builder.res - Factory & Construction  
- **Purpose**: Create component instances using the builder pattern
- **Contains**: `Make` functor with all dependencies as parameters
- **Pattern**: Uses first-class modules for type-safe dependency injection

### Optional Files

#### Component_Adapter.res - Provider-Agnostic Interface
- **Purpose**: Define abstract interface for infrastructure dependencies
- **When used**: When component needs external storage, messaging, or other infrastructure
- **Contains**: Module types that abstract away provider-specific implementations
- **Key insight**: Uses generic types (`string`, `Js.Json.t`) that any provider can implement

#### Component_Operations.res - Runtime Operations
- **Purpose**: Implement type-safe runtime operations
- **When used**: When component provides runtime operations for other components
- **Contains**: `Make` functor that transforms generic adapter operations into type-safe operations
- **Key insight**: Handles serialization/deserialization between domain types and generic JSON

#### Component_Callback.res - Runtime Handlers
- **Purpose**: Implement runtime behavior (event/command handlers)
- **When used**: For components that process messages at runtime
- **Contains**: `Make` functor that creates message handlers
- **Example**: `Aggregate_Callback.res` - Handles command processing for aggregates

## Generic Component Wrapper

All components use the generic `Component.t<'component, 'outputs, 'operations>` wrapper:

- **Unified interface**: Consistent API across all components
- **Pulumi integration**: Seamless infrastructure-as-code support
- **outputs vs operations**: Clear distinction between deploy-time outputs and runtime operations

## Complete Example: EventLog Component

The EventLog component demonstrates the full pattern with all optional files:

### File Structure

```
reventless/core/src/components/EventLog/
├── EventLog.res           # Core types and interface
├── EventLog_Builder.res   # Factory/construction
├── EventLog_Adapter.res   # Provider-agnostic adapter interface
└── EventLog_Operations.res # Runtime operations
```

### 1. EventLog.res - Interface & Types

```rescript
// Type definitions
type outputs = {resources: array<resource>, eventTopic: EventTopic.outputs}
type append<'id, 'event> = (int, 'id, array<'event>) => promise<result<unit, string>>
type replay<'id, 'event> = 'id => promise<array<'event>>

// Spec module type - what users provide
module type Spec = {
  module Id: Reventless.Id.T
  let name: string
  @schema type event
}

// T module type - what the component exposes
module type T = {
  module Spec: Spec
  type operations = {
    append: append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>,
    replay: replay<Spec.Id.t, Spec.event>,
  }
  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
```

### 2. EventLog_Adapter.res - Provider-Agnostic Interface

```rescript
// Generic operations using string/JSON - provider-agnostic
type operations = {
  append: EventLog.append<string, Js.Json.t>,
  replay: EventLog.replay<string, Js.Json.t>,
}

// Storage type returned by adapter implementations
type storage = {
  resources: array<Reventless.Adapter.resource>,
  operations: Pulumi.Output.t<operations>,
}

// Module type that adapter implementations must satisfy
module type Storage = {
  let make: (~name: string, ~opts: Pulumi.CustomResourceOptions.t) => storage
}
```

**Key insight**: The adapter uses `string` for IDs and `Js.Json.t` for events - these are generic types that any provider can work with. The type-safe conversion happens in Operations.

### 3. EventLog_Operations.res - Runtime operations

```rescript
// Dependencies module type
module type Ops = {
  module Spec: EventLog.Spec
  module EventTopic: EventTopic.T with module Spec.Id = Spec.Id
  let eventTopic: EventTopic.operations
  let storage: EventLog_Adapter.operations  // Generic operations
}

// Output module type
module type T = {
  module Spec: EventLog.Spec
  let append: EventLog.append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>
  let replay: EventLog.replay<Spec.Id.t, Spec.event>
}

// Make functor - transforms generic to type-safe
module Make = (Spec: EventLog.Spec, Ops: Ops with module Spec = Spec): T => {
  // Encoding: Spec.event -> Js.Json.t
  let encodeEvent' = (id, event') => { /* ... */ }
  
  // Decoding: Js.Json.t -> Spec.event
  let decodeEvent = (id, json) => { /* ... */ }
  
  // Type-safe append using generic storage
  let append = async (sequenceNr, id, events') => {
    let eventsJson = events'->encodeEvents'(id)
    await Ops.storage.append(sequenceNr, id->Spec.Id.toString, eventsJson)
  }
  
  // Type-safe replay using generic storage
  let replay = async id => {
    let eventsJson = await Ops.storage.replay(id->Spec.Id.toString)
    eventsJson->decodeEvents(id->Spec.Id.toString)
  }
}
```

**Key insight**: Operations handles serialization/deserialization, converting between type-safe domain types and generic JSON that adapters work with.

### 4. EventLog_Builder.res - Factory & Construction

```rescript
module Make = (
  Spec: EventLog.Spec,
  Storage: EventLog_Adapter.Storage,      // Adapter interface
  EventTopicPublisher: EventTopic_Adapter.Publisher,
): EventLog.T => {
  
  let construct = (self, name) => {
    // Create storage using adapter
    let storage = Storage.make(~name, ~opts)
    
    // Create EventTopic component
    module SpecificEventTopic = EventTopic_Builder.Make(Spec, EventTopicPublisher)
    let eventTopic = SpecificEventTopic.make(~name, ~storageResources=storage.resources, ~opts)
    
    // transform low level operations from storage and eventTopic into EventLog operations
    self->Component.setOperations(
      (storage.operations, eventTopic->Component.operations)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((storage, eventTopic)) => {
        // Create Ops module by providing Adapter operations
        module Ops = EventLog_Operations.Make(
          Spec,
          {
            module Spec = Spec
            module EventTopic = SpecificEventTopic
            let eventTopic = eventTopic
            let storage = storage
          },
        )
        {append: Runtime.append, replay: Runtime.replay}
      }),
    )
  
    // transform low level outputs from storage and eventTopic into EventLog outputs
    self->Component.setOutputs({
      EventLog.resources: storage.resources,
      eventTopic: eventTopic->Component.outputs,
    })
}
}
```
In the call to `Component.setOperations`, we're using `Pulumi.Output.apply` to transform the adapter's operations into the component's operations. Similar to that, the call to `Component.setOutputs` is used to transform the adapter's outputs into the component's outputs.

### Data Flow Diagram

```d2
UserCode: User Code {
  Spec: "EventLog.Spec\nUser-defined types" { class: spec }
}

ComponentFiles: Component Files {
  Interface: "EventLog.res\nType definitions"
  Builder: "EventLog_Builder.res\nFactory"
  Adapter: "EventLog_Adapter.res\nAbstract interface" { class: adapter }
  Operations: "EventLog_Operations.res\nRuntime operations"
}

ProviderImpl: Provider Implementation {
  AWSAdapter: "AWS EventLog Storage\nDynamoDB implementation" { class: aws-service }
}

TypeSafeOps: "Type-safe operations\nappend/replay"

UserCode.Spec -> ComponentFiles.Builder
ComponentFiles.Interface -> ComponentFiles.Builder
ComponentFiles.Adapter -> ComponentFiles.Builder
ProviderImpl.AWSAdapter -> ComponentFiles.Builder
ComponentFiles.Builder -> ComponentFiles.Operations
ComponentFiles.Operations -> TypeSafeOps
```

## Component_Callback Example: Aggregate_Callback

The `Aggregate_Callback.res` file demonstrates the Component_Callback pattern for handling command processing:

### Structure

```rescript
// Dependencies module type
module type Ops = {
  module Spec: Reventless.Aggregate.Spec
  module EventLog: EventLog.T with module Spec.Id = Spec.Id and type Spec.event = Spec.event
  let eventLog: EventLog.operations
}

// Output module type
module type T = {
  module Spec: Reventless.Aggregate.Spec
  let handleCommands: CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>
}

// Make functor - creates command handler
module Make = (
  Spec: Reventless.Aggregate.Spec,
  Behavior: Behavior.T with module Spec := Spec,
  Ops: Ops with module Spec = Spec,
): T => {
  // Command processing logic
  let handleCommands = async topicItems => {
    // Group commands by aggregate ID
    // Replay event history for each aggregate
    // Execute business logic via Behavior
    // Append generated events to EventLog
    // Return processing results
  }
}
```

### Key Responsibilities

1. **Command Processing**: Receives batches of commands from CommandTopic
2. **Event Sourcing**: Replays event history to reconstruct aggregate state
3. **Business Logic**: Delegates to Behavior module for domain logic
4. **Event Generation**: Collects events generated by business logic
5. **Persistence**: Appends new events to EventLog
6. **Error Handling**: Manages errors and provides meaningful feedback

### Integration with Builder

The Aggregate_Builder wires the callback at runtime:

```rescript
// In Aggregate_Builder.res
self->Component.setOperations(
  // ... other operations
  ->Pulumi.Output.apply(operations => {
    module CallbackOps = {
      module Spec = Spec
      module EventLog = SpecificEventLog
      let eventLog = operations.eventLog
    }
    module Callback = Aggregate_Callback.Make(Spec, Behavior, CallbackOps)
    
    {
      // ... other operations
      handleCommands: Callback.handleCommands,
    }
  })
)
```

**Key insight**: The Callback pattern separates message handling logic from component construction, making it easier to test and reason about runtime behavior independently from infrastructure concerns.

## Creating a New Component

### Step-by-step Guide

1. **Define types in Component.res**
   - Create `outputs`, `operations`, and `component` types
   - Define module type `Spec` for user configuration
   - Define module type `T` for component interface

2. **Create Component_Builder.res**
   - Implement `Make` functor with all dependencies
   - Use `Component.make` with construct function
   - Wire dependencies using `Pulumi.Output.apply`

3. **Add Component_Adapter.res (if needed)**
   - Define module types for infrastructure dependencies
   - Use generic types (`string`, `Js.Json.t`) for provider independence

4. **Add Component_Operations.res (if needed)**
   - Implement runtime operations with type-safe operations
   - Handle serialization/deserialization
   - Transform generic adapter operations to typed operations

5. **Add Component_Callback.res (if needed)**
   - Implement message handlers for runtime behavior
   - Use `Make` functor pattern for type safety

### Code Template

```rescript
// Component.res
type outputs = { /* ... */ }
type operations = { /* ... */ }
type component = Component.t<t, outputs, operations>

module type Spec = { /* user configuration */ }
module type T = { /* component interface */ }
```

```rescript
// Component_Builder.res
module Make = (Spec: Component.Spec, /* other deps */): Component.T => {
  let construct = (self, name) => {
    // Create infrastructure
    // Wire operations
    // Set outputs
  }
  
  let make = (~name, ~opts=?) => Component.make(~componentType, ~name, ~construct, ~opts)
}
```

## Rationale

### Why This Pattern?

1. **Type Safety**: Module types ensure compile-time correctness
2. **Clear Separation of Concerns**: Each file has a single responsibility
3. **Provider Independence**: Adapters abstract infrastructure details
4. **Testability**: Each layer can be tested independently
5. **Pulumi Integration**: Builder handles deploy-time vs runtime separation
6. **Consistency**: Same pattern across all components
7. **Extensibility**: Easy to add new components following the pattern

## Examples in Codebase

### Core Components
- **[Aggregate](/app/components/aggregate)** - Uses Builder, Callback
- **[ReadModel](/app/components/readmodel)** - Uses Builder
- **[API](/app/graphql-api-guide)** - GraphQL schema definition pattern

### Infrastructure Components
- **[EventLog](/framework/runtime-components/eventlog)** (`EventLog/`) - Uses all files (complete example)
- **[CommandTopic](/framework/runtime-components/commandtopic)** (`CommandTopic/`) - Uses Builder, Adapter, Operations, Callback
- **[EventTopic](/framework/runtime-components/eventtopic)** (`EventTopic/`) - Uses Builder, Adapter, Operations
- **[EventCollector](/framework/runtime-components/eventcollector)** (`EventCollector/`) - Uses Builder, Adapter
- **[QueryDb](/framework/runtime-components/querydb)** (`QueryDb/`) - Uses Builder, Adapter, Operations

### Processing Components
- **[CommandGenerator](/framework/runtime-components/commandgenerator)** (`CommandGenerator/`) - Uses Builder, Callback
- **[EventMapper](/framework/runtime-components/eventmapper)** - Uses Builder pattern for event-to-command mapping
- **[SideEffectHandler](/app/components/sideeffecthandler)** - Uses Builder pattern for event-triggered side effects
- **[Counter](/framework/runtime-components/counter)** (`Counter/`) - Uses Builder, Operations

### Plugin System Components
- **[Plugin](/app/components/plugin)** - Deployment unit organization
- **[ExtensionPoint](/app/components/extensionpoint)** (`ExtensionPoint/`) - Uses Builder, Operations
- **[Extension](/app/components/extension)** (`Extension/`) - Uses Builder, Operations

### Scheduling Components
- **[Scheduler](/framework/runtime-components/scheduler)** - Time-based command publishing
- **[Heartbeat](/framework/runtime-components/heartbeat)** - Periodic health check signals
- **[Task](/app/components/task)** - File-based task processing

## Related Documentation

- [Framework Internals](./framework-internals.md) - Overall architecture
- [Messages](./messages.md) - Message flow patterns
- [Pulumi Integration](./pulumi.md) - Infrastructure as code
- [ReScript Syntax](/app/rescript-syntax) - Language features (functors, first-class modules)