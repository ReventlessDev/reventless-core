---
title: Counter
date: 2026-01-26
draft: false
---

For a short summary of Counter, see [Reventless Components Overview.](../component-overview.md#counter)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/inner-workings/component-structure-pattern), using separate files for interface definitions (`Counter.res`), builder logic (`Counter_Builder.res`), runtime operations (`Counter_Operations.res`), and runtime callbacks (`Counter_Callback.res`).
:::

## Overview

```d2
EventMapper: Event Mapper { class: event-mapper }
Counter: Counter { class: counter }
TargetHandler: Target Handler { class: event-mapper }

CounterComponent: Counter Component {
  ReferencesDb: References DB { class: query-db }
  CountsDb: Counts DB { class: query-db }

  ReferencesDb -> CountsDb: track references
  CountsDb -> ReferencesDb: countdown
}

EventMapper -> Counter: 1. Count
EventMapper -> Counter: 2. AddToCounterTarget
Counter -> TargetHandler: 3. Triggered event { class: event-flow }
```

The **Counter** component enables coordination across multiple events by counting references and triggering actions when a target count is reached. It's primarily used in EventMappers to implement patterns like "wait for N events before proceeding" or collecting data from multiple sources before generating a command.

## Purpose and Responsibilities

- **Responsibility**: Track event references by counter ID; countdown to zero when references are collected; emit Triggered events when count reaches zero; collect target data from multiple events; enable multi-event coordination patterns
- **In**: Count operations and target data from EventMapper
- **Out**: Triggered events (Counter.CountFinished) when count reaches zero

## Counter Operations

The Counter provides two main operations:

### Count Operation

Tracks references and increments/decrements counters:

```rescript
type countItem = {
  counterId: string,      // Unique counter identifier
  reference: string,      // Reference (typically correlationId)
  inc: int,              // Increment value (positive or negative)
}

type count = array<countItem> => promise<unit>
```

**Usage:**
```rescript
// Increment counter by 1
await count([{
  counterId: "order-123",
  reference: "correlation-abc",
  inc: 1
}])

// Set expected count (negative value)
await count([{
  counterId: "order-123",
  reference: "expected-count",
  inc: -5  // Expect 5 items
}])
```

### AddToCounterTarget Operation

Associates target data with a counter for later retrieval:

```rescript
type counterTargetRef = {
  counterId: string,      // Counter identifier
  target: 'a,            // Target data to collect
  targetRef: string,     // Reference for this target
}

type addToCounterTarget = counterTargetRef => promise<unit>
```

**Usage:**
```rescript
// Collect order items
await addToCounterTarget({
  counterId: "order-123",
  target: {itemId: "item-1", quantity: 2, price: 19.99},
  targetRef: "correlation-abc"
})
```

## Usage Pattern

### Counter in EventMappings

The Counter is used within an Aggregate's `<Entity>_Mappings.res` file
(`@@reventless.mappings`). The PPX injects `module Target`, `module type Mapping`,
`let counter = None`, and `open Reventless.EventMapping` (so `Count`,
`CountMulti`, `AddToCounterTarget`, `Publish` are in scope unqualified). Override
`let counter` to enable the Counter:

```rescript title="Invoice/Aggregate/Invoice_Mappings.res" showLineNumbers
@@reventless.mappings

// Map Order events to Invoice commands
module OrderMapping = {
  module Source = Order

  let map = (orderId, event, _queryEngine) =>
    switch event {
    | Order.Created({expectedItems}) => [
        // Set the expected count (negative number)
        CountMulti(orderId->Order.Id.toString, -expectedItems), // Expect this many items
      ]
    | Order.ItemAdded({itemId, quantity, price}) => [
        // Add item data to counter targets
        AddToCounterTarget({counterId: orderId->Order.Id.toString, target: {itemId, quantity, price}}),
        // Increment counter by 1
        Count(orderId->Order.Id.toString),
      ]
    | Order.ItemRemoved(_) => [
        // Decrement counter when item removed
        CountMulti(orderId->Order.Id.toString, -1),
      ]
    | _ => []
    }
}

// Handle Counter.CountFinished events
module CounterMapping = {
  module Source = Counter.Source

  let map = (counterId, event, _queryEngine) =>
    switch event {
    | Counter.Source.CountFinished =>
      // Counter reached zero — all items collected; targets hold the data
      [Publish(counterId->Invoice.Id.fromString, Invoice.Generate)]
    }
}

let mappings: array<module(Mapping)> = [module(OrderMapping), module(CounterMapping)]

// Enable counter for this EventMapper (overrides the default `let counter = None`)
let counter = Some(module(Invoice_Counter: Counter.T))
```

## Runtime Behavior

### Counter Countdown Sequence

```d2
shape: sequence_diagram

EventMapper: EventMapper
Counter: Counter
ReferencesDb: References DB { class: query-db }
CountsDb: Counts DB { class: query-db }
Handler: Counter Handler { class: external-system }

EventMapper -> Counter: "Phase 1 — count([{counterId, ref1, inc: -3}])"
Counter -> ReferencesDb: "save(counterId#ref1, inc: -3)"
Counter -> CountsDb: "count(counterId, -3)  → count = -3"

EventMapper -> Counter: "Phase 2 — count([{counterId, ref2, inc: 1}])"
Counter -> ReferencesDb: "save(counterId#ref2, inc: 1)"
Counter -> CountsDb: "count(counterId, 1)  → count = -2"

EventMapper -> Counter: "count([{counterId, ref3, inc: 1}])"
Counter -> ReferencesDb: "save(counterId#ref3, inc: 1)"
Counter -> CountsDb: "count(counterId, 1)  → count = -1"

EventMapper -> Counter: "count([{counterId, ref4, inc: 1}])"
Counter -> ReferencesDb: "save(counterId#ref4, inc: 1)"
Counter -> CountsDb: "count(counterId, 1)  → count = 0"
Counter -> Handler: "trigger(counterId, count: 0)"
Handler -> EventMapper: CountFinished event
```

### With Target Collection

```d2
shape: sequence_diagram

EventMapper: EventMapper
Counter: Counter
CounterDb: Counter DBs { class: query-db }
Handler: Handler { class: external-system }

EventMapper -> Counter: "addToCounterTarget({id, target1, ref1})"
EventMapper -> Counter: "count([{id, ref1, inc: 1}])"

EventMapper -> Counter: "addToCounterTarget({id, target2, ref2})"
EventMapper -> Counter: "count([{id, ref2, inc: 1}])"

EventMapper -> Counter: "addToCounterTarget({id, target3, ref3})"
EventMapper -> Counter: "count([{id, ref3, inc: 1}])  → count reaches 0"

Counter -> Handler: "CountFinished(id, targets: [target1, target2, target3])"
Handler -> EventMapper: "handleCounterEvents([event])"
EventMapper -> EventMapper: Process collected targets / Generate commands
```

## Integration Points

### With EventMapper

The Counter is created as part of an EventMapper when the EventMappings specify a counter:

```rescript
// In EventMappings file
let counter = Some(module(MyCounter: Counter.T))
```

The EventMapper automatically wires the Counter and handles its Triggered events through a special CounterMapping.

### Counter Event Source

The Counter emits events as `Counter.Source`:

```rescript
module Counter.Source = {
  let name = "Counter"
  
  type event = 
    | CountFinished
}
```

These events can be mapped like any other aggregate events.

## Common Patterns

These per-source modules live inside an `@@reventless.mappings` file, so the
action constructors (`Count`, `CountMulti`, `AddToCounterTarget`, `Publish`) are
in scope unqualified.

### Wait for Multiple Events

```rescript
// Wait for 3 confirmations before proceeding
module ConfirmationMapping = {
  module Source = Confirmation

  let map = (requestId, event, _queryEngine) =>
    switch event {
    | Confirmation.RequestCreated => [CountMulti(requestId, -3)] // Set expected count to 3
    | Confirmation.Approved(_) => [Count(requestId)] // Each approval increments counter
    | _ => []
    }
}

module CounterMapping = {
  module Source = Counter.Source

  let map = (requestId, event, _queryEngine) =>
    switch event {
    | Counter.Source.CountFinished => [Publish(requestId, Request.Execute)] // All 3 approvals received
    }
}
```

### Collect Data from Multiple Sources

```rescript
// Collect order items before generating invoice
module OrderItemMapping = {
  module Source = OrderItem

  let map = (itemId, event, _queryEngine) =>
    switch event {
    | OrderItem.Added({orderId, quantity, price}) => [
        // Store item data
        AddToCounterTarget({counterId: orderId, target: {itemId, quantity, price}}),
        // Increment counter
        Count(orderId),
      ]
    | OrderItem.Removed({orderId}) => [CountMulti(orderId, -1)] // Decrement counter if item removed
    | _ => []
    }
}

module CounterMapping = {
  module Source = Counter.Source

  let map = (orderId, event, _queryEngine) =>
    switch event {
    | Counter.Source.CountFinished =>
      // Counter provides collected targets; generate invoice with all collected items
      [Publish(orderId->Invoice.Id.fromString, Invoice.GenerateFromItems)]
    }
}
```

### Saga Coordination

```rescript
// Coordinate multi-step process
module SagaMapping = {
  module Source = Process

  let map = (processId, event, _queryEngine) =>
    switch event {
    | Process.Started({steps}) => [CountMulti(processId, -steps)] // Set expected count to number of steps
    | Process.StepCompleted(_) => [Count(processId)] // Each step completion increments
    | Process.StepFailed(_) => [CountMulti(processId, 1000)] // On failure, push count away from 0 to prevent completion
    | _ => []
    }
}

module CounterMapping = {
  module Source = Counter.Source

  let map = (processId, event, _queryEngine) =>
    switch event {
    | Counter.Source.CountFinished => [Publish(processId, Process.Complete)] // All steps completed successfully
    }
}
```

### Dynamic Count Targets

```rescript
// Handle variable number of items
module OrderMapping = {
  module Source = Order

  let map = (orderId, event, _queryEngine) =>
    switch event {
    | Order.Created({items}) => [
        // Set count based on number of items
        CountMulti(orderId->Order.Id.toString, -(items->Array.length)),
      ]
    | Order.ItemShipped({itemId}) => [
        AddToCounterTarget({counterId: orderId->Order.Id.toString, target: {itemId, shippedAt: Date.now()}}),
        Count(orderId->Order.Id.toString),
      ]
    | _ => []
    }
}
```

## Error Handling

The Counter includes error handling for common scenarios:

**Reference Tracking Errors:**
- Failed to save reference → raises `NotCounted` exception
- EventMapper retries count operation
- References are stored with TTL to prevent stale data

**Count Errors:**
- Failed to decrement count → logged and retried
- Count never reaches zero → TTL causes cleanup
- Duplicate references → each counted separately

**Recovery:**
- Counter references have configurable TTL (default: 1 week)
- Stale counters are automatically cleaned up
- Failed count operations are retried with backoff

## Pulumi

The Counter component creates these infrastructure resources:

```rescript
type outputs = {
  referencesDb: QueryDb.outputs,  // Stores count references
  countsDb: QueryDb.outputs,       // Stores counter values
}

type operations = {
  count: count,                        // Count operation
  addToCounterTarget: addToCounterTarget, // Target collection operation
}
```

**Resource Naming:**
- Component type: `reventless:Counter`
- Resource name pattern: `{targetAggregateName}Counter`
- References DB: `{name}References`
- Counts DB: `{name}Counts`

**Configuration:**
- `ttl` - Time-to-live for counter data (default: 1 week)
- Prevents stale counters from accumulating
- Configurable per Counter instance

## Data Storage

### References Database

Tracks individual count operations:

```rescript
type referencesState = {
  id: string,     // "counterId#reference"
  inc: int,       // Increment value
}
```

### Counts Database

Maintains current count values:

```rescript
type countsState = {
  id: string,     // counterId
  count: int,     // Current count value
}
```

**When count reaches 0:**
- Triggered event is emitted
- Counter handler invokes `counterEventsHandler`
- EventMapper processes CountFinished event

## Best Practices

### Use Negative Numbers for Expected Counts

```rescript
// ✅ Good: Set expected count as negative
CountMulti(orderId, -5) // Expect 5 items

// Then increment with positive numbers
Count(orderId) // +1 each time

// Counter triggers when: -5 + 1 + 1 + 1 + 1 + 1 = 0
```

### Use Correlation IDs as References

```rescript
// ✅ Good: Use event correlation ID
Count(orderId)
// Internally uses event.meta.correlationId as reference

// This ensures each event is counted exactly once
```

### Clean Up with TTL

```rescript
// ✅ Good: Set appropriate TTL
let counter = Counter.make(
  ~name="OrderCounter",
  ~ttl=24 * 60 * 60,  // 1 day
  ~counterEventsHandler,
)

// Prevents accumulation of abandoned counters
```

### Handle Counter Completion

```rescript
// ✅ Good: Always handle Counter.Source events
module CounterMapping = {
  module Source = Counter.Source

  let map = (counterId, event, _queryEngine) =>
    switch event {
    | Counter.Source.CountFinished => [Publish(counterId, SomeCommand)] // Take action when counter completes
    }
}

// Include in the mappings array
let mappings: array<module(Mapping)> = [
  module(CounterMapping),
  // ... other mappings
]
```

## Related Components

- **[EventMapper](./eventmapper.md)** - Primary user of Counter for event coordination
- **[Aggregate](./aggregate.md)** - Defines EventMappings that may use Counter
- **[QueryDb](./querydb.md)** - Underlying storage for counter data
- **[EventCollector](./eventcollector.md)** - Delivers Counter.Source events

## AWS Implementation

For detailed AWS implementation, see Counter AWS adapter documentation (TBD).

## Replacing the Old counter.md

:::note Migration
The Counter is a full component, not just a common module, and its primary use is within EventMappings for multi-event coordination patterns.
:::