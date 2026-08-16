# Writing Unit Tests

This guide covers unit testing for application developers building applications with Reventless.

## Overview

Unit tests verify your **business logic** without any infrastructure dependencies. Reventless provides test helpers that make it easy to test:

- **Aggregate behaviors** - Command handling and event generation
- **Read model projections** - Event-to-state transformations
- **Event mappings** - Cross-aggregate communication

## Test Helpers

The framework provides three test helper modules in `packages/reventless/test-helper/`:

### BehaviorTest

Tests aggregate behaviors using a **given-when-then** pattern. This is the primary way to test your aggregate's command handling and event generation logic.

```rescript
module PluginTest = BehaviorTest.Make(PluginSpec, PluginBehavior)
open PluginTest

describe("PluginBehavior:", () => {
  test("Heartbeat - first", () =>
    givenEvents([])
    ->whenCmd(Heartbeat)
    ->thenEvents([UnknownPluginDetected])
  )

  test("Connect", () =>
    givenEvents([UnknownPluginDetected])
    ->whenCmd(Connect(pluginDefinition))
    ->thenEvents([Connected(pluginDefinition)])
  )

  test("Connect - already connected", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(AlreadyConnected)
  )
})
```

#### Core Test Functions

The given-when-then pattern relies on two key setup functions:

**Setup Functions:**

| Function | Purpose |
|----------|---------|
| [`givenEvents(events)`] | Sets up the initial event history for the aggregate. This represents the current state of the aggregate before executing the command being tested. |
| [`whenCmd(command)`] | Executes the specified command against the aggregate with the given event history. This is the action being tested. |

**Available Assertions:**

| Assertion | Purpose |
|-----------|---------|
| `thenEvents(events)` | Verify specific events were generated |
| `thenEvent(event)` | Verify a single event was generated |
| `thenNoEvent` | Verify no events were generated |
| `thenError(error)` | Verify an error was returned |
| `thenEventWithError(event, error)` | Verify both event and error |
| `thenCompareEvent(event, compareFn)` | Verify event with custom comparison |
| `thenCompareEvents(events, compareFn)` | Verify events with custom comparison |

### ProjectionTest

Tests read model projections that transform events into query-optimized state.

```rescript
module PluginProjectionTest = ProjectionTest.Make(PluginProjection.PluginMapping)
open PluginProjectionTest

describe("PluginProjection:", () => {
  test("Connected", () =>
    givenEvents([UnknownPluginDetected])
    ->whenEvent(Connected(pluginDefinition))
    ->thenState({...state, status: Connected})
  )

  test("Disconnected", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenEvent(Disconnected(pluginDefinition))
    ->thenState({...state, status: Disconnected})
  )
  
  test("Delete on deactivate", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenEvent(Deactivated(pluginDefinition))
    ->thenNoState
  )
})
```

#### Core Test Functions

**Setup Functions:**

| Function | Purpose |
|----------|---------|
| [`givenEvents(events)`] | Sets up the initial event history that will be used to build the projection state before applying the test event. |
| [`whenEvent(event)`] | Applies the specified event to the projection, triggering the state transformation logic being tested. |

**Available Assertions:**

| Assertion | Purpose |
|-----------|---------|
| `thenState(state)` | Verify the resulting state |
| `thenStates(states)` | Verify multiple states (for multi-state projections) |
| `thenStateWithId(id, state)` | Verify state for a specific ID |
| `thenStatesWithId(id, states)` | Verify multiple states for a specific ID |
| `thenAllStates(store)` | Verify all states in the store |
| `thenNoState` | Verify no state was created |
| `thenFail` | Verify the projection failed |
| `thenThrow` | Verify the projection threw an exception |

### EventMappingTest

Tests event mappings between aggregates (for cross-aggregate communication).

```rescript
module MyMappingTest = EventMappingTest.Make(
  SourceSpec,
  SourceBehavior,
  TargetSpec,
  TargetBehavior,
  MyEventMapping,
)
open MyMappingTest

describe("MyEventMapping:", () => {
  test("Source event maps to target command", () =>
    givenSourceEvents([])
    ->givenTargetEvents([])
    ->whenSourceCmd("source-id", CreateSource(data))
    ->thenTargetEvent("target-id", TargetCreated(mappedData))
  )
  
  test("No mapping for certain events", () =>
    givenSourceEvents([Created(data)])
    ->givenTargetEvents([])
    ->whenSourceCmd("source-id", InternalUpdate(data))
    ->thenNoTargetEvent
  )
})
```

#### Core Test Functions

**Setup Functions:**

| Function | Purpose |
|----------|---------|
| [`givenSourceEvents(events)`] | Sets up the initial event history for the source aggregate. |
| [`givenTargetEvents(events)`] | Sets up the initial event history for the target aggregate. |
| [`whenSourceCmd(id, command)`] | Executes a command on the source aggregate with the given ID, which may trigger event mappings to the target aggregate. |

**Available Assertions:**

| Assertion | Purpose |
|-----------|---------|
| `thenTargetEvents(events)` | Verify target events by ID |
| `thenTargetEvent(id, event)` | Verify a single target event |
| `thenNoTargetEvent` | Verify no target events were generated |

## Complete Examples

Here are comprehensive examples showing how to set up and use each type of test:

### BehaviorTest Example

This example shows testing a Plugin aggregate that manages plugin lifecycle:

```rescript
// PluginBehaviorTest.res
open PluginSpec
open PluginFixtures

module PluginTest = BehaviorTest.Make(PluginSpec, PluginBehavior)
open PluginTest

describe("PluginBehavior:", () => {
  // Test initial state - no events in history
  test("Heartbeat on new plugin creates UnknownPluginDetected", () =>
    givenEvents([])
    ->whenCmd(Heartbeat)
    ->thenEvents([UnknownPluginDetected])
  )

  // Test successful command execution
  test("Connect command on detected plugin creates Connected event", () =>
    givenEvents([UnknownPluginDetected])
    ->whenCmd(Connect(pluginDefinition))
    ->thenEvents([Connected(pluginDefinition)])
  )

  // Test business rule violation
  test("Connect command on already connected plugin returns error", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(Connect(pluginDefinition))
    ->thenError(AlreadyConnected)
  )

  // Test complex state transitions
  test("Heartbeat after disconnect triggers reconnection", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Disconnected(pluginDefinition),
    ])
    ->whenCmd(Heartbeat)
    ->thenEvents([Reconnected(pluginDefinition)])
  )

  // Test idempotent operations
  test("Heartbeat on connected plugin produces no events", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenCmd(Heartbeat)
    ->thenNoEvent
  )
})
```

### ProjectionTest Example

This example shows testing a read model projection that builds plugin state:

```rescript
// PluginProjectionTest.res
open PluginSpec
open PluginFixtures

module PluginProjectionTest = ProjectionTest.Make(PluginProjection.PluginMapping)
open PluginProjectionTest

describe("PluginProjection:", () => {
  // Test projection creates no state for detection events
  test("UnknownPluginDetected creates no state", () =>
    givenEvents([])
    ->whenEvent(UnknownPluginDetected)
    ->thenNoState
  )

  // Test projection creates state from connection event
  test("Connected event creates plugin state with Connected status", () =>
    givenEvents([UnknownPluginDetected])
    ->whenEvent(Connected(pluginDefinition))
    ->thenState({...state, status: Connected})
  )

  // Test projection updates existing state
  test("Disconnected event updates status to Disconnected", () =>
    givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
    ->whenEvent(Disconnected(pluginDefinition))
    ->thenState({...state, status: Disconnected})
  )

  // Test projection handles events without prior state
  test("Connected event works even without prior detection", () =>
    givenEvents([])
    ->whenEvent(Connected(pluginDefinition))
    ->thenState({...state, status: Connected})
  )

  // Test complex state transitions
  test("Reconnected after activation sets status to Connected", () =>
    givenEvents([
      UnknownPluginDetected,
      Connected(pluginDefinition),
      Deactivated(pluginDefinition),
      Activated(pluginDefinition),
    ])
    ->whenEvent(Reconnected(pluginDefinition))
    ->thenState({...state, status: Connected})
  )
})
```

### EventMappingTest Example

This example shows testing event mappings between a User aggregate and a Notification aggregate:

```rescript
// UserNotificationMappingTest.res
open UserSpec
open NotificationSpec
open UserNotificationFixtures

module UserNotificationTest = EventMappingTest.Make(
  UserSpec,
  UserBehavior,
  NotificationSpec,
  NotificationBehavior,
  UserNotificationMapping,
)
open UserNotificationTest

describe("UserNotificationMapping:", () => {
  // Test successful event mapping
  test("User registration triggers welcome notification", () =>
    givenSourceEvents([])
    ->givenTargetEvents([])
    ->whenSourceCmd("user-123", RegisterUser({
      email: "user@example.com",
      name: "John Doe",
    }))
    ->thenTargetEvent("notification-user-123", NotificationCreated({
      userId: "user-123",
      type_: Welcome,
      message: "Welcome to our platform, John Doe!",
      createdAt: TestFixtures.timestamp,
    }))
  )

  // Test conditional mapping
  test("User profile update does not trigger notification", () =>
    givenSourceEvents([UserRegistered({
      email: "user@example.com",
      name: "John Doe",
    })])
    ->givenTargetEvents([])
    ->whenSourceCmd("user-123", UpdateProfile({
      name: "John Smith",
    }))
    ->thenNoTargetEvent
  )

  // Test mapping with existing target state
  test("Password reset triggers notification even with existing notifications", () =>
    givenSourceEvents([UserRegistered({
      email: "user@example.com",
      name: "John Doe",
    })])
    ->givenTargetEvents([NotificationCreated({
      userId: "user-123",
      type_: Welcome,
      message: "Welcome!",
      createdAt: TestFixtures.timestamp,
    })])
    ->whenSourceCmd("user-123", ResetPassword({
      email: "user@example.com",
    }))
    ->thenTargetEvent("notification-user-123", NotificationCreated({
      userId: "user-123",
      type_: PasswordReset,
      message: "Your password has been reset",
      createdAt: TestFixtures.timestamp,
    }))
  )

  // Test error handling in mapping
  test("Invalid user command does not trigger notification", () =>
    givenSourceEvents([])
    ->givenTargetEvents([])
    ->whenSourceCmd("user-123", RegisterUser({
      email: "", // Invalid email
      name: "John Doe",
    }))
    ->thenNoTargetEvent
  )
})
```

## Best Practices

### 1. Use Descriptive Test Names

```rescript
// Good - describes the scenario and expected outcome
test("Connect command on unknown plugin creates Connected event", ...)

// Avoid - unclear what is being tested
test("test1", ...)
```

### 2. Test One Behavior Per Test

```rescript
// Good - focused test
test("Heartbeat on new plugin creates UnknownPluginDetected", () =>
  givenEvents([])
  ->whenCmd(Heartbeat)
  ->thenEvents([UnknownPluginDetected])
)

// Avoid - testing multiple behaviors makes failures harder to diagnose
test("Heartbeat and Connect", () =>
  givenEvents([])
  ->whenCmd(Heartbeat)
  ->thenEvents([UnknownPluginDetected])
  ->whenCmd(Connect(def))
  ->thenEvents([Connected(def)])
)
```

### 3. Use Fixtures for Complex Data

Create a fixtures file to share test data across tests:

```rescript
// In PluginFixtures.res
let pluginDefinition = {
  Reventless.Plugin.id: "id@1",
  name: "name",
  version: "1",
  extensionPoints: [],
  extensions: [{name: "Platform.Plugin.Test", extensionPointName: "Platform.Plugin"}],
  eventCollector: "eventCollector",
}

let state: PluginReadModelSpec.state = {
  name: pluginDefinition.name,
  version: pluginDefinition.version,
  eventCollector: pluginDefinition.eventCollector,
  extensionPoints: pluginDefinition.extensionPoints,
  extensionPointNames: [],
  extensionNames: ["Platform.Plugin.Test"],
  extensions: pluginDefinition.extensions,
  status: Connected,
  statusChange: TestFixtures.statusChange,
}
```

```rescript
// In test file
open PluginFixtures

test("Connect", () =>
  givenEvents([UnknownPluginDetected])
  ->whenCmd(Connect(pluginDefinition))
  ->thenEvents([Connected(pluginDefinition)])
)
```

### 4. Verify Both Success and Error Cases

```rescript
// Success case
test("Connect succeeds on unknown plugin", () =>
  givenEvents([UnknownPluginDetected])
  ->whenCmd(Connect(pluginDefinition))
  ->thenEvents([Connected(pluginDefinition)])
)

// Error case
test("Connect fails on already connected plugin", () =>
  givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
  ->whenCmd(Connect(pluginDefinition))
  ->thenError(AlreadyConnected)
)
```

### 5. Test Edge Cases

```rescript
// Empty history (new aggregate)
test("First heartbeat", () =>
  givenEvents([])
  ->whenCmd(Heartbeat)
  ->thenEvents([UnknownPluginDetected])
)

// Long history with multiple state transitions
test("Heartbeat after multiple state changes", () =>
  givenEvents([
    UnknownPluginDetected,
    Connected(pluginDefinition),
    Deactivated(pluginDefinition),
    Activated(pluginDefinition),
  ])
  ->whenCmd(Heartbeat)
  ->thenEvents([Reconnected(pluginDefinition)])
)
```

### 6. Test Idempotency Where Applicable

```rescript
test("Heartbeat is idempotent on connected plugin", () =>
  givenEvents([UnknownPluginDetected, Connected(pluginDefinition)])
  ->whenCmd(Heartbeat)
  ->thenNoEvent
)
```

## Running Tests

```bash
# Navigate to your package
cd packages/reventless

# Run all tests
pnpm test

# Run specific test file
npx jest tests/plugin/PluginBehaviorTest.res.js

# Run tests in watch mode (re-runs on file changes)
pnpm run dev

# Run tests with coverage
pnpm run coverage
```

## File Structure

Organize your tests alongside your domain code:

```
packages/your-plugin/
├── src/
│   ├── MyAggregate/
│   │   ├── MyAggregateSpec.res      # Types: command, event, error
│   │   └── MyAggregateBehavior.res  # Business logic
│   └── MyReadModel/
│       ├── MyReadModelSpec.res      # Types: state
│       └── MyReadModelProjection.res # Projection logic
├── tests/
│   ├── MyAggregateBehaviorTest.res
│   ├── MyReadModelProjectionTest.res
│   └── MyFixtures.res
└── package.json
```

## See Also

- [Get Started](./get-started.md) - Getting started with Reventless
- [Aggregate](./components/aggregate.md) - Aggregate component documentation
- [ReadModel](./components/readmodel.md) - ReadModel component documentation
