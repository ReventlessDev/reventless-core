# Component Testing Guide for Reventless

## Purpose

This guide provides a standardized approach for testing Reventless components. It's based on patterns discovered during DCB component testing and existing test suites (PluginBehaviorTest, MessageTest, ProjectionTest).

Use this guide when adding tests for **any** Reventless component:
- Core components (Aggregate, EventLog, ReadModel, Plugin, etc.)
- New components (DcbEventLog, CommandHandler, etc.)
- Adapter implementations (DynamoDB, S3, SQS, etc.)

> **Slice-level Given-When-Then tests** — aggregate `Behavior`, DCB
> `StateChangeSlice`, read-model projections, DCB `StateViewSlice`,
> automation / translation slices, and cross-pattern `Mapping_GWT` — are
> covered by [`docs/guides/given-when-then.md`](/app/given-when-then) and run
> through the `reventless-gwt` CLI. This guide is for the component /
> integration layer that sits below them (mocks, adapters, callbacks,
> operations).

---

## Quick Reference: Test Structure Template

```
packages/<package-name>/tests/<component-name>/
├── <Component>Fixtures.res     # Test specs, mocks, fixtures
├── <Component>Test.res         # Pure unit tests (sync)
├── <Component>OperationsTest.res  # Runtime logic tests (async)
└── <Component>CallbackTest.res    # Handler/callback tests (async)
```

**Example** (DCB components):
```
packages/reventless/tests/dcb/
├── DcbFixtures.res
├── DcbTagTest.res
├── DcbEventLogOperationsTest.res
└── DcbCommandHandlerTest.res
```

---

## Component Architecture Pattern Recap

Reventless components follow a consistent structure (see `packages/doc/docs/internals/component-structure-pattern.md`):

| File | Purpose | Tests Needed |
|------|---------|--------------|
| `Component.res` | Type definitions, outputs | Schema validation, type safety |
| `Component_Builder.res` | Factory using functors | Integration tests (wire-up) |
| `Component_Adapter.res` | Provider-agnostic adapter interface | Adapter compliance tests |
| `Component_Operations.res` | Runtime business logic | Unit tests (encode/decode, logic) |
| `Component_Callback.res` | Runtime handlers | Handler behavior tests (async) |

**Testing priority**:
1. **Operations** — Core business logic (highest value)
2. **Callbacks** — Handler behavior with mocks
3. **Adapters** — Interface compliance (can use in-memory mocks)
4. **Builder** — Integration (lowest priority, often covered by usage tests)

---

## Step 1: Create Test Fixtures (`<Component>Fixtures.res`)

Shared infrastructure for all component tests.

### What to Include

#### 1.1 Test Spec Modules

Create minimal spec modules satisfying the component's `Spec` module type:

```rescript
// For a component with module type Spec = { let name: string; @schema type event; ... }
module TestEventLogSpec: EventLog.Spec = {
  let name = "TestEventLog"

  @schema
  type event =
    | ItemCreated({id: string, name: string})
    | ItemUpdated({id: string, field: string, value: string})
}
```

**Guidelines**:
- Keep specs **minimal** — only what's needed to exercise the component
- Use **realistic domain examples** (items, users, orders) for clarity
- Include **positive cases** (normal variants) and **negative cases** (untagged/invalid) if relevant

#### 1.2 Mock Adapters

Implement in-memory versions of adapter interfaces:

```rescript
type mockStorage = {
  operations: Component_Adapter.operations,
  getState: unit => 'state,  // Inspect internal state
  setState: 'state => unit,  // Pre-seed state
  reset: unit => unit,       // Clear state between tests
}

let makeMockStorage = (): mockStorage => {
  let state = ref(initialState)

  let read = async (~query) => {
    // In-memory implementation
  }

  let write = async (data) => {
    // In-memory implementation
  }

  {
    operations: {read, write},
    getState: () => state.contents,
    setState: (s) => state := s,
    reset: () => state := initialState,
  }
}
```

**Key patterns from DCB tests**:

1. **Factory function returning closures** (not global refs):
   ```rescript
   let makeMockStorage = (): mockStorage => {
     let data = ref([])  // Fresh state per test

     let read = async () => data.contents
     let write = async (item) => data := data.contents->Array.concat([item])

     {operations: {read, write}, ...}
   }
   ```

2. **Inspection functions** for assertions:
   ```rescript
   type mockStorage = {
     operations: Adapter.operations,
     getEvents: unit => array<rawEvent>,        // Inspect stored data
     publishedMessages: ref<array<published>>,  // Capture side effects
   }
   ```

3. **Failure injection** for error path testing:
   ```rescript
   type mockStorage = {
     // ...
     failNextWrites: ref<int>,  // Counter: fail N operations then succeed
   }

   let write = async (data) => {
     if failNextWrites.contents > 0 {
       failNextWrites := failNextWrites.contents - 1
       Error("injected failure")
     } else {
       // normal write
     }
   }
   ```

4. **Reset function** for `beforeEach`:
   ```rescript
   let reset = () => {
     data := []
     publishedMessages := []
     failNextWrites := 0
   }
   ```

#### 1.3 Test Data Fixtures

Common test values reused across test files:

```rescript
let testMeta: Message.meta = {
  service: "test",
  time: "2024-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId: "msg-1",
  correlationId: "corr-1",
}

let sampleEvent1 = TestSpec.ItemCreated({id: "item-1", name: "First"})
let sampleEvent2 = TestSpec.ItemUpdated({id: "item-1", field: "name", value: "Updated"})
```

---

## Step 2: Pure Unit Tests (`<Component>Test.res`)

Synchronous tests for pure functions (no async, no mocks).

### What to Test

- **Utility functions**: Parsing, serialization, validation
- **Type conversions**: JSON encoding/decoding helpers
- **Pure logic**: Calculations, transformations, filtering

### Example: Testing a utility module

```rescript
open Jest
open Expect

describe("ComponentUtils:", () => {
  describe("parseId", () => {
    test("valid UUID returns Some", () => {
      expect(ComponentUtils.parseId("550e8400-e29b-41d4-a716-446655440000"))
      ->toEqual(Some("550e8400-e29b-41d4-a716-446655440000"))
    })

    test("invalid string returns None", () => {
      expect(ComponentUtils.parseId("not-a-uuid"))->toEqual(None)
    })
  })

  describe("extractTags", () => {
    test("tagged field extracts correctly", () => {
      let event = TestSpec.ItemCreated({id: "item-1", name: "Test"})
      expect(ComponentUtils.extractTags(TestSpec.eventSchema, event))
      ->toEqual([{key: "id", value: "item-1"}])
    })

    test("untagged variant returns empty array", () => {
      let event = UntaggedSpec.PlainEvent({data: "test"})
      expect(ComponentUtils.extractTags(UntaggedSpec.eventSchema, event))
      ->toEqual([])
    })
  })
})
```

### Patterns

- **Given/When/Then style** test names:
  - ✅ `"valid UUID returns Some"`
  - ✅ `"tagged field extracts correctly"`
  - ❌ `"test parseId"` (too vague)

- **Organize by function** with nested `describe` blocks

- **Test edge cases**:
  - Empty inputs
  - Boundary values
  - Invalid/malformed data

---

## Step 3: Operations Tests (`<Component>OperationsTest.res`)

Async tests for runtime business logic (typically `Component_Operations.res`).

### Setup Pattern

```rescript
open Jest
open Expect

let mock = ComponentFixtures.makeMockStorage()

module TestOps: Component_Operations.Ops with module Spec = ComponentFixtures.TestSpec = {
  module Spec = ComponentFixtures.TestSpec
  let storage = mock.operations
  // ... other dependencies
}

module Ops = Component_Operations.Make(ComponentFixtures.TestSpec, TestOps)

let _ = beforeEach(() => mock.reset())
```

**Key points**:
- Use `with module Spec = ...` to refine the module type
- Call `mock.reset()` in `beforeEach` to isolate tests
- Instantiate the functor once (not per test)

### What to Test

#### 3.1 Round-trip Tests (Encode/Decode)

Test that domain values survive serialization:

```rescript
describe("round-trip (write then read)", () => {
  testPromise("ItemCreated preserves through round-trip", async () => {
    let event = ComponentFixtures.TestSpec.ItemCreated({id: "item-1", name: "Test"})
    let _ = await Ops.write(event)
    let result = await Ops.read("item-1")

    expect(result)->toEqual(Some(event))
  })

  testPromise("multiple items all read back", async () => {
    let events = [event1, event2, event3]
    let _ = await Ops.writeAll(events)
    let result = await Ops.readAll()

    expect(result)->toEqual(events)
  })
})
```

**Watch out for** (learned from DCB tests):
- **Payload-less variants** may not round-trip correctly (depending on serialization strategy)
- **Tagged schemas** need `@s.matches` on the **type expression**, not field name:
  ```rescript
  // ✅ Correct:
  {id: @s.matches(DcbTag.string) string}

  // ❌ Wrong (silently ignored):
  {@s.matches(DcbTag.string) id: string}
  ```

#### 3.2 Business Logic Tests

Test the core operations:

```rescript
describe("append", () => {
  testPromise("stores event and publishes to topic", async () => {
    let event = TestSpec.ItemCreated({id: "item-1", name: "Test"})
    let result = await Ops.append([event])

    expect((
      Result.isOk(result),
      mock.getEvents()->Array.length,
      mock.publishedMessages.contents->Array.length,
    ))->toEqual((true, 1, 1))
  })

  testPromise("error from storage does not publish", async () => {
    mock.failNextWrites := 1
    let result = await Ops.append([event])

    expect((
      Result.isError(result),
      mock.publishedMessages.contents->Array.length,
    ))->toEqual((true, 0))
  })
})

describe("read", () => {
  testPromise("returns empty for non-existent ID", async () => {
    let result = await Ops.read("non-existent")
    expect(result)->toEqual(None)
  })

  testPromise("filters by query parameter", async () => {
    let _ = await Ops.append([event1, event2])
    let result = await Ops.read(~query={status: "active"})

    expect(result->Array.length)->toEqual(1)
  })
})
```

#### 3.3 Error Handling

Test failure paths:

```rescript
describe("error handling", () => {
  testPromise("storage failure returns Error", async () => {
    mock.failNextWrites := 1
    let result = await Ops.write(data)

    expect(Result.isError(result))->toBe(true)
  })

  testPromise("invalid data returns Error", async () => {
    let result = await Ops.write(invalidData)

    expect(result)->toEqual(Error("validation failed"))
  })
})
```

---

## Step 4: Callback/Handler Tests (`<Component>CallbackTest.res`)

Async tests for event handlers, command handlers, or callback logic.

### Setup Pattern

For components with multiple dependencies (e.g., CommandHandler needs DcbEventLog):

```rescript
let mock = ComponentFixtures.makeMockStorage()

// Instantiate dependency components
module DependencyOps = Dependency_Operations.Make(...)

// Stub module for unused builder functions
module StubDependency = {
  module Spec = DependencySpec
  type operations = {read: ..., write: ...}
  type component = Dependency.component<operations>

  // Never called in tests — satisfies module type only
  let make = (~name as _, ~opts as _=?): component => Obj.magic(0)
}

// Instantiate component under test
module TestOps = {
  module Spec = ComponentFixtures.TestSpec
  module Dependency = StubDependency
  let dependency: StubDependency.operations = {
    read: DependencyOps.read,
    write: DependencyOps.write,
  }
}

module Handler = Component_Callback.Make(ComponentFixtures.TestSpec, TestOps)
```

**Pattern**: Use `Obj.magic(0)` for builder functions (`make`) that aren't called in tests. Document clearly: `// Never called — satisfies module type only`.

### What to Test

#### 4.1 Happy Path

Test normal execution flow:

```rescript
describe("handleCommand - happy path", () => {
  testPromise("CreateItem succeeds and emits event", async () => {
    let command = TestSpec.CreateItem({id: "item-1", name: "Test"})
    let result = await Handler.handleCommand(command)

    expect((
      Result.isOk(result),
      mock.getEvents()->Array.length,
    ))->toEqual((true, 1))
  })

  testPromise("emitted event has correct data", async () => {
    let _ = await Handler.handleCommand(command)
    let event = mock.getEvents()->Array.getUnsafe(0)

    expect(event.eventType)->toEqual("ItemCreated")
  })
})
```

#### 4.2 Error Cases

Test failure paths:

```rescript
describe("handleCommand - errors", () => {
  testPromise("invalid state returns Error", async () => {
    // Pre-seed conflicting state
    mock.setState({exists: true})

    let command = TestSpec.CreateItem({id: "item-1", name: "Test"})
    let result = await Handler.handleCommand(command)

    expect(result)->toEqual(Error("ItemAlreadyExists"))
  })

  testPromise("error does not emit events", async () => {
    mock.setState({exists: true})
    let _ = await Handler.handleCommand(createCommand)

    expect(mock.publishedMessages.contents->Array.length)->toEqual(0)
  })
})
```

#### 4.3 Retry/Concurrency Logic

Test retry mechanisms (if applicable):

```rescript
describe("handleCommand - retry on conflict", () => {
  testPromise("retries and succeeds after 1 failure", async () => {
    mock.failNextWrites := 1
    let result = await Handler.handleCommand(command)

    expect((
      Result.isOk(result),
      mock.getEvents()->Array.length,
    ))->toEqual((true, 1))
  })

  testPromise("returns Error after retries exhausted", async () => {
    mock.failNextWrites := 4  // Exhaust all retries
    let result = await Handler.handleCommand(command)

    expect((
      Result.isError(result),
      mock.getEvents()->Array.length,
    ))->toEqual((true, 0))
  })
})
```

**Counter-based failure injection** (from DCB tests):
- Use `failNextOperations: ref<int>` counter in mock
- Decrement on each call, fail if > 0
- Enables **deterministic** retry testing (no race conditions)

#### 4.4 Batch Handling

If the handler processes batches:

```rescript
describe("handleCommands - batch", () => {
  testPromise("multiple successful commands", async () => {
    let results = await Handler.handleCommands([command1, command2])

    expect(results)->toEqual([Ok("ref-1"), Ok("ref-2")])
  })

  testPromise("mixed success and failure", async () => {
    // Pre-seed state to cause second command to fail
    let results = await Handler.handleCommands([validCommand, invalidCommand])

    expect(results)->toEqual([Ok("ref-1"), Error("ref-2")])
  })

  testPromise("empty batch returns empty array", async () => {
    let results = await Handler.handleCommands([])

    expect(results)->toEqual([])
  })
})
```

---

## ReScript Testing Patterns & Gotchas

### Pattern 1: Type Annotations for Record Field Resolution

**Problem**: ReScript loses track of record types in pattern matching.

```rescript
// ❌ Fields not resolved:
switch optionalRecord {
| Some(rec) => rec.field  // Error: field not found
| None => defaultValue
}

// ✅ Add type annotation:
switch optionalRecord {
| Some(rec: RecordType) => rec.field  // Works
| None => defaultValue
}
```

### Pattern 2: Abstract Types Need Constructors

**Problem**: Abstract types (defined in `.resi` files) don't unify with primitives.

```rescript
// ❌ Type error:
id: "string-value"  // Expected: Id.t, got: string

// ✅ Use constructor:
id: Id.makeFromString("string-value")
```

**Common in Reventless**:
- `Reventless.Id.String.t` — use `Id.String.makeFromString()`
- `Reventless.Id.Int.t` — use `Id.Int.makeFromInt()`

### Pattern 3: Return Type Annotations for Abstract Types

**Problem**: Type inference fails for functions returning values with abstract types.

```rescript
// ❌ Infers wrong type (string instead of Id.t):
let makeCommand = (ref, cmd) => {
  command: {
    id: Id.makeFromString("cmd-" ++ ref),
    command: cmd,
  },
  reference: ref,
}

// ✅ Explicit return type:
let makeCommand = (ref, cmd): CommandTopic.topicItem<
  Message.command'<Id.String.t, TestSpec.command>
> => {
  command: {
    id: Id.makeFromString("cmd-" ++ ref),
    command: cmd,
  },
  reference: ref,
}
```

### Pattern 4: Module Type Refinement with `with`

**Problem**: Functor expects a module with a specific `Spec`, but the constraint is abstract.

```rescript
// ❌ Type mismatch (Spec is abstract):
module TestOps: Component_Operations.Ops = {
  module Spec = TestSpec
  // ...
}

// ✅ Refine with `with module Spec = ...`:
module TestOps: Component_Operations.Ops with module Spec = TestSpec = {
  module Spec = TestSpec
  // ...
}
```

### Pattern 5: `@s.matches` on Type Expressions

**Problem**: Placing `@s.matches(schema)` on the field name is silently ignored.

```rescript
// ❌ Silently ignored by sury-ppx:
{@s.matches(DcbTag.string) fieldName: string}

// ✅ On type expression (after colon):
{fieldName: @s.matches(DcbTag.string) string}
```

**Verification**: Check compiled `.res.mjs` output:
- ✅ Correct: `s.m(DcbTag$Reventless.string)`
- ❌ Wrong: `s.m(S.string)`

### Pattern 6: Payload-less Variants May Not Round-trip

**Problem**: Variants without payloads (e.g., `| SimpleEvent`) may not survive encode/decode depending on serialization strategy.

**Example from DCB tests**:
- sury serializes `SimpleEvent` to JSON string `"SimpleEvent"`
- `Message.splitMessage` expects JSON object with `TAG` field
- Result: crashes with `"Unknown"` event type

**Solution**: If your component uses `Message.splitMessage`/`combineMessage`, avoid payload-less variants in production code. Test them separately for `extractTags` (works correctly), but exclude from round-trip tests.

### Pattern 7: `Obj.magic` for Stubbing Unused Functions

**Use case**: Module type requires a function that won't be called in tests.

```rescript
module StubComponent = {
  module Spec = TestSpec
  type operations = {...}
  type component = Component.component<operations>

  // Never called — satisfies module type only
  let make = (~name as _, ~opts as _=?): component => Obj.magic(0)
}
```

**Safety**:
- Document clearly: `// Never called — satisfies module type only`
- If accidentally called, fails immediately (doesn't corrupt state)
- Only use for builder functions, not for operations used in tests

---

## Test Organization Guidelines

### File Naming

```
<Component>Fixtures.res       # Test specs, mocks, test data
<Component>Test.res           # Pure unit tests (sync)
<Component>OperationsTest.res # Runtime logic tests (async)
<Component>CallbackTest.res   # Handler tests (async)
<Component>AdapterTest.res    # Adapter compliance tests (if needed)
```

### Directory Structure

```
packages/<package-name>/tests/
├── <component1>/
│   ├── <Component1>Fixtures.res
│   ├── <Component1>Test.res
│   └── <Component1>OperationsTest.res
├── <component2>/
│   ├── <Component2>Fixtures.res
│   └── <Component2>Test.res
└── integration/
    └── <Scenario>IntegrationTest.res
```

**Example** (existing):
```
packages/reventless/tests/
├── plugin/
│   ├── PluginFixtures.res
│   ├── PluginBehaviorTest.res
│   └── PluginProjectionTest.res
├── dcb/
│   ├── DcbFixtures.res
│   ├── DcbTagTest.res
│   ├── DcbEventLogOperationsTest.res
│   └── DcbCommandHandlerTest.res
├── MessageTest.res
└── TestFixtures.res
```

### Test Naming Conventions

#### Describe Blocks

```rescript
describe("<ComponentName>:", () => {          // Top level: component name
  describe("<functionName>", () => {          // Second level: function/operation
    describe("- <scenario>", () => {          // Third level: scenario category
      testPromise("<specific case>", ...)     // Test case: specific behavior
    })
  })
})
```

**Example**:
```rescript
describe("CommandHandler_Callback:", () => {
  describe("handleCommand", () => {
    describe("- happy path", () => {
      testPromise("CreateItem succeeds and emits event", async () => {
        // ...
      })
    })

    describe("- error cases", () => {
      testPromise("invalid state returns Error", async () => {
        // ...
      })
    })
  })
})
```

#### Test Case Names

Use **Given/When/Then** style:

```rescript
// ✅ Good (describes behavior):
"ItemCreated preserves through round-trip"
"error from storage does not publish"
"returns empty array for non-existent ID"
"retries and succeeds after 1 failure"

// ❌ Bad (too vague):
"test append"
"check read"
"handle error"
```

---

## Mock Storage Design Patterns

### Pattern A: In-Memory Array Storage

For event logs, message queues, simple stores:

```rescript
let makeMockStorage = (): mockStorage => {
  let items = ref([])
  let position = ref(0)

  let append = async (newItems) => {
    items := items.contents->Array.concat(newItems)
    position := position.contents + newItems->Array.length
    Ok(position.contents->Int.toString)
  }

  let read = async (~after=?) => {
    let filtered = switch after {
    | Some(pos) => items.contents->Array.filter(item => item.position > pos)
    | None => items.contents
    }
    {items: filtered}
  }

  {
    operations: {append, read},
    getItems: () => items.contents,
    reset: () => {
      items := []
      position := 0
    },
  }
}
```

### Pattern B: In-Memory Dict Storage

For key-value stores, databases:

```rescript
let makeMockStorage = (): mockStorage => {
  let store = ref(Dict.make())

  let get = async (key) => {
    store.contents->Dict.get(key)
  }

  let set = async (key, value) => {
    store.contents->Dict.set(key, value)
    Ok()
  }

  {
    operations: {get, set},
    getAll: () => store.contents,
    reset: () => store := Dict.make(),
  }
}
```

### Pattern C: Side Effect Capture

For publishers, notifiers, external service calls:

```rescript
let makeMockPublisher = (): mockPublisher => {
  let published = ref([])

  let publish = async (service, meta, json) => {
    published := published.contents->Array.concat([{service, meta, json}])
  }

  {
    publishJson: publish,
    getPublished: () => published.contents,
    reset: () => published := [],
  }
}
```

### Pattern D: Failure Injection

For retry logic, error handling:

```rescript
let makeMockStorage = (): mockStorage => {
  let data = ref([])
  let failNextAppends = ref(0)

  let append = async (items) => {
    if failNextAppends.contents > 0 {
      failNextAppends := failNextAppends.contents - 1
      Error("injected failure")
    } else {
      data := data.contents->Array.concat(items)
      Ok(data.contents->Array.length->Int.toString)
    }
  }

  {
    operations: {append},
    failNextAppends: failNextAppends,  // Test sets this
    reset: () => {
      data := []
      failNextAppends := 0
    },
  }
}
```

**Usage**:
```rescript
mock.failNextAppends := 1  // Next call fails, then succeeds
mock.failNextAppends := 4  // Exhaust retries (if max 3 retries)
```

---

## Verification Checklist

Before submitting component tests:

### Build & Test
- [ ] `npm run build` — All modules compile
- [ ] `npm test` — All tests pass (new + existing)
- [ ] `npx jest tests/<component>/` — Isolated component tests pass

### Coverage
- [ ] **Pure functions** tested (utils, conversions)
- [ ] **Round-trip** tested (encode → decode → matches original)
- [ ] **Business logic** tested (core operations, edge cases)
- [ ] **Error paths** tested (invalid inputs, storage failures)
- [ ] **Retry logic** tested (if applicable, using counter-based injection)
- [ ] **Side effects** captured and verified (publishes, notifications)

### Code Quality
- [ ] No `Obj.magic` except for unused builder functions (documented)
- [ ] Mock storage uses factory functions (not global refs)
- [ ] `beforeEach(() => mock.reset())` isolates tests
- [ ] Type annotations where needed (record fields, abstract types)
- [ ] Test names follow Given/When/Then style

### Documentation
- [ ] Fixtures file has comments explaining test specs
- [ ] Complex mocks have comments explaining behavior
- [ ] Findings/gotchas documented (if discovered new patterns)

---

## Common Test Scenarios by Component Type

### Event Log Components

Test:
- Round-trip: event → JSON → event
- Replay: read events for aggregate ID
- Append: optimistic concurrency (sequence numbers)
- Position tracking: `after` parameter filters correctly

### Command Handler Components

Test:
- Decide: produces correct events from commands
- Reduce: builds decision model from events
- Retry: on conditional append conflict
- Batch: multiple commands, mixed success/failure

### Read Model Components

Test:
- Projection: events → queryable state
- Query: filters, pagination, sorting
- Rebuild: from event stream
- Consistency: eventual consistency guarantees

### Topic Components (Command/Event Topics)

Test:
- Publish: message enqueued
- Subscribe: message delivered to handler
- Ordering: FIFO guarantees (if applicable)
- Batching: multiple messages processed together

### Adapter Components

Test:
- Interface compliance: satisfies adapter module type
- Error handling: network failures, timeouts
- Resource creation: Pulumi resources generated correctly
- Runtime behavior: actual storage operations work

---

## Integration Testing (Optional)

For complex multi-component scenarios:

### File: `tests/integration/<Scenario>IntegrationTest.res`

```rescript
// Example: Full command flow
describe("Command flow integration:", () => {
  testPromise("command → events → read model update", async () => {
    // Setup: wire up Aggregate + EventLog + ReadModel
    let eventLog = ...
    let aggregate = ...
    let readModel = ...

    // Execute: send command
    let _ = await aggregate.executeCommand(createCommand)

    // Verify: event stored
    let events = await eventLog.replay(aggregateId)
    expect(events->Array.length)->toEqual(1)

    // Verify: read model updated
    let state = await readModel.query({id: aggregateId})
    expect(state)->toEqual(Some(expectedState))
  })
})
```

**When to write integration tests**:
- Multi-component workflows (command → events → projections)
- Adapter interoperability (DynamoDB + SQS + SNS)
- End-to-end scenarios (API → domain → storage → query)

**Keep integration tests separate** from unit tests (slower, harder to debug).

---

## Examples from Existing Codebase

### Pure Unit Tests

- **`MessageTest.res`** — Tests `splitMessage`, `combineMessage`, `generateMeta`
  - Synchronous, no mocks
  - Covers JSON encoding/decoding edge cases

### Operations Tests

- **`DcbEventLogOperationsTest.res`** — Tests encode/decode, append, read
  - Async with mock storage
  - Round-trip tests for event preservation
  - Side effect verification (publishJson calls)

### Callback/Handler Tests

- **`DcbCommandHandlerTest.res`** — Tests reduce/decide loop, retry logic
  - Async with multiple mocks (storage + publisher)
  - Retry testing with counter-based failure injection
  - Batch processing with mixed results

### Behavior Tests

- **`PluginBehaviorTest.res`** — Tests Aggregate behavior (init/apply/execute)
  - Uses `BehaviorTest` helper module
  - Given/When/Then test structure
  - Focuses on domain logic, not infrastructure

### Projection Tests

- **`PluginProjectionTest.res`** — Tests ReadModel projection
  - Uses `ProjectionTest` helper module
  - Event stream → state transformation
  - Query verification

---

## Quick Start Checklist

To add tests for a new component:

1. [ ] Create `tests/<component>/` directory
2. [ ] Create `<Component>Fixtures.res`:
   - [ ] Test spec module(s)
   - [ ] Mock adapter(s) with factory function
   - [ ] Test data fixtures
3. [ ] Create `<Component>Test.res` (if pure functions exist):
   - [ ] Test utils, conversions, pure logic
4. [ ] Create `<Component>OperationsTest.res`:
   - [ ] Round-trip tests
   - [ ] Business logic tests
   - [ ] Error handling tests
5. [ ] Create `<Component>CallbackTest.res` (if handlers exist):
   - [ ] Happy path tests
   - [ ] Error case tests
   - [ ] Retry/batch tests (if applicable)
6. [ ] Run `npm run build && npm test`
7. [ ] Document any new patterns/gotchas discovered

---

## References

- [Component structure pattern](./internals/component-structure-pattern.md)
- Existing tests: `reventless/core/tests/`
- Jest bindings: `@reventlessdev/rescript-jest` (`JestGlobals`)
- Sury: the `sury-ppx` package README

---

## Maintenance

This guide should be updated when:
- New testing patterns are discovered
- New component types are added
- ReScript/sury-ppx version changes affect testing
- Better mock patterns are identified

**Last updated**: Based on DCB component testing (2024)
