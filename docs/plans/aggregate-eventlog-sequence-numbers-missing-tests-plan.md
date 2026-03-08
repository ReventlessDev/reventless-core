# Plan: Missing Tests for Aggregate EventLog Sequence Numbers

**Parent plan**: [aggregate-eventlog-sequence-numbers-plan.md](./done/aggregate-eventlog-sequence-numbers-plan.md)

## Overview

Three test categories remain unchecked in Step 6 of the parent plan. This plan covers the implementation approach, required infrastructure, and detailed test cases for each.

---

## Step 1: In-Memory E2E — Concurrent Write Simulation

Simulate a concurrent write by injecting events into the shared storage between the aggregate's replay and append phases. This verifies the full retry cycle through real in-memory components (not mocked).

### Approach

The `AggregateTest.res` E2E test uses real in-memory adapters wired via `Aggregate_Builder.Make(Bus)`. The aggregate's `publishJsons` triggers the full `handleCommands` flow: replay → process → append.

To simulate concurrency:
1. Send a CreateItem command for aggregate "agg-X" → stores 1 event
2. Replay "agg-X" via the storage adapter to get direct access to the underlying EventLog operations
3. Manually append an event directly to storage (simulating a concurrent writer)
4. Send another command for "agg-X" — the replay count will include the injected event, so the first append attempt will conflict (sequenceNr from the stale replay ≠ actual count)
5. The retry loop should re-replay, see the new count, and succeed

### Location

- New file: `reventless/reventless-in-memory/tests/components/aggregate/AggregateConcurrentTest.res`
- New fixtures: `reventless/reventless-in-memory/tests/components/aggregate/AggregateConcurrentFixtures.res`

### Fixture Design

The fixture needs a Bus-wired aggregate where we can also access the underlying EventLog storage directly to inject events. Use `EventLogStorage_InMemory.makeStorage` (which returns `(name, replay, storage)`) to retain a reference to the raw storage operations alongside the aggregate builder.

```
module Bus = InMemory_Bus.Make()

// Create storage directly to retain raw access
let (_, _, rawStorage) = EventLogStorage_InMemory.makeStorage(~name="ConcItem", ~opts)
// Register replay on Bus for EventLog wiring
Bus.registerEventLogReplay("ConcItem", rawReplay)

// Build aggregate using the same storage
module ConcAgg = ...
```

Alternatively: since `EventLogStorage_InMemory.Make(Bus)` registers replay internally, create a separate `EventLogStorage_InMemory.make` instance and wire it manually, OR expose the internal storage operations via a module-level ref in the fixture.

**Simpler approach**: Use `EventLogStorage_InMemory.make` to create a standalone storage, then build the EventLog component manually with `EventLog_Builder.Make(Spec, Storage, EventTopicPublisher)`. Store a reference to the raw storage `operations` (via `TestRunner.resolve`) so tests can call `rawOps.append(...)` directly to inject events.

### Test Cases

- [ ] **concurrent write triggers conflict and retry succeeds**: Send CreateItem → inject event into storage → send another command → verify the command succeeds (retry detected conflict and re-replayed)
- [ ] **injected event is visible after retry**: After the retry succeeds, replay the aggregate and verify all events are present (original + injected + new)

### Dependencies

- `EventLogStorage_InMemory.makeStorage` must remain accessible (it's already a public `let` binding)
- The aggregate builder needs to accept a custom storage maker or the fixture must wire components manually

---

## Step 2: AWS Adapter Unit Tests — Adaptive Strategy

Unit-test `EventLogStorage_DynamoDb_Runtime` by mocking the DynamoDB SDK calls. Verify the adaptive strategy selects the correct write method and maps errors correctly.

### Infrastructure Required

**No AWS test project exists.** Required setup:

- [ ] Add `tests/` source directory to `reventless/reventless-aws/rescript.json` sources
- [ ] Add Jest project entry to root `jest.config.js`:
  ```js
  {
    displayName: "reventless-aws",
    rootDir: "./reventless/reventless-aws",
    testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
    moduleFileExtensions: ["js", "mjs"],
  }
  ```
- [ ] Create `reventless/reventless-aws/tests/` directory
- [ ] Create `reventless/reventless-aws/tests/AsyncTest.res` (copy from reventless-core or import)

### Mocking Strategy

The functions under test (`putItemConditional`, `putItemsSequentialConditional`, `transactWriteConditional`, `appendWithCondition`) call DynamoDB SDK bindings: `PutCommand.send` and `TransactWriteCommand.send`. These are `@module` externals that resolve to `@aws-sdk/lib-dynamodb`.

**Option A — Mock at the SDK level** (preferred): Use Jest's module mocking to intercept `@aws-sdk/lib-dynamodb` imports. The compiled `.res.mjs` files import `PutCommand` and `TransactWriteCommand` from the SDK. Jest's `moduleNameMapper` or `jest.mock()` can substitute a mock implementation.

**Option B — Test through the public `append` function**: Since `append` is the public API and it calls `appendWithCondition` internally, mock the DynamoDB client singleton (`DynamoDb_DocumentClient.clientInstance`) to return a mock client whose `send` method records calls and returns controlled responses.

**Recommended**: Option B — mock the client singleton. The client is a `ref(None)` that gets lazily initialized. Tests can set `clientInstance := Some(mockClient)` before calling `append`.

### Test File Structure

```
reventless/reventless-aws/tests/
├── AsyncTest.res                          # Test framework bindings
├── adapter/
│   └── EventLogAdaptiveAppendTest.res     # Adaptive strategy tests
└── errors/
    └── DynamoDbErrorTest.res              # Error classification tests (optional)
```

### Test Cases — Adaptive Strategy Selection

Each test creates a `runtimeTable` value and calls `append(table)` with a controlled number of JSON items, then verifies which SDK method was invoked.

- [ ] **1 event → putItemConditional (single PutCommand.send)**: Call `append(table)(0, "id", [json1])`. Verify `PutCommand.send` was called exactly once with `conditionExpression: "attribute_not_exists(sequenceNr)"`.
- [ ] **3 events → putItemsSequentialConditional**: Call `append(table)(0, "id", [json1, json2, json3])`. Verify `PutCommand.send` was called 3 times, each with the condition expression.
- [ ] **7 events → transactWriteConditional (TransactWriteCommand.send)**: Call `append(table)(0, "id", sevenJsons)`. Verify `TransactWriteCommand.send` was called exactly once with 7 `transactItems`, each having `conditionExpression: "attribute_not_exists(sequenceNr)"`.
- [ ] **5 events → putItemsSequentialConditional (boundary)**: Verify 5-event batch uses sequential PutItem (upper boundary of the 2-5 range).
- [ ] **6 events → transactWriteConditional (boundary)**: Verify 6-event batch uses TransactWriteItems (lower boundary of the 6+ range).

### Test Cases — ConditionalCheckFailedException Mapping

- [ ] **PutCommand ConditionalCheckFailedException → Error("conflict")**: Mock `PutCommand.send` to throw a JS error with `name: "ConditionalCheckFailedException"`. Call `append(table)(0, "id", [json])`. Verify result is `Error("conflict")`.
- [ ] **TransactWrite ConditionalCheckFailedException → Error("conflict")**: Mock `TransactWriteCommand.send` to throw `ConditionalCheckFailedException`. Call `append(table)(0, "id", sevenJsons)`. Verify `Error("conflict")`.
- [ ] **Sequential PutItems: first item conflicts → stops and returns Error("conflict")**: Mock first `PutCommand.send` to throw `ConditionalCheckFailedException`. Verify only 1 call was made (short-circuits) and result is `Error("conflict")`.
- [ ] **Other DynamoDB errors → non-conflict error**: Mock to throw `InternalServerError`. Verify result is `Error(...)` but NOT `Error("conflict")`.

### Mock Client Implementation

```rescript
// Mock client that records calls
type mockCall =
  | PutCommand({item: JSON.t, conditionExpression: option<string>})
  | TransactWrite({itemCount: int})

let makeMockClient = () => {
  let calls: ref<array<mockCall>> = ref([])
  let failWith: ref<option<string>> = ref(None) // Error name to throw

  // Create mock send that records calls and optionally throws
  let mockSend = command => {
    // Record the call type based on command shape
    // If failWith is set, throw a JS error with that name
    // Otherwise return a success response
  }

  (calls, failWith, mockSend)
}
```

### Alternative: Pure Function Testing

Since `putItemConditional`, `putItemsSequentialConditional`, `transactWriteConditional`, and `appendWithCondition` are module-level `let` bindings (not inside a functor), they can't easily be tested in isolation without mocking the SDK.

However, `appendWithCondition` is a pure function that takes `(tableName, jsons)` and returns an `Effect`. We can test it by:
1. Running the Effect
2. Catching the JS error from the mock client
3. Verifying the error classification

This is the most practical approach since the functions are already at module scope.

---

## Step 3: Verification Checklist

After implementing the tests:

- [ ] All new tests pass (`npm test`)
- [ ] No warnings from `npm run build`
- [ ] No existing tests broken
- [ ] Update parent plan to check off remaining Step 6 items
- [ ] Move parent plan to `docs/plans/done/` if all steps complete

---

## Out of Scope

- **Integration tests against real DynamoDB**: Requires LocalStack or DynamoDB Local; separate concern
- **Load/stress testing**: Concurrent write simulation is deterministic, not a load test
- **DCB EventLog tests**: DCB uses a separate position system, unaffected
