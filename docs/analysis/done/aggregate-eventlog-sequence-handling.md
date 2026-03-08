# Analysis: Aggregate EventLog Sequence Handling

## Context

The aggregate-based EventLog was originally designed with integer sequence numbers for ordering and optimistic locking. Due to concurrency issues encountered during development, timestamps replaced integer sequence numbers. The current implementation generates a high-resolution timestamp string (`{milliseconds}-{nanoseconds}`) at encode time, stored as the DynamoDB sort key. The `sequenceNr` parameter passed to `append()` is counted during replay but **ignored** by the storage adapter — no optimistic locking is enforced.

This analysis evaluates the current state, the target state (real sequence numbers with optimistic locking), and the implications of that change.

---

## Current Implementation

### Sequence Number Generation

Events receive their sequence identifier in `EventLog_Operations.res` at encode time:

```rescript
// EventLog_Operations.res (encodeEvent')
("sequenceNr", JSON.Encode.string(
  Message.hrtimeToString(~hrtime=Message.hrtime(), ~now=Message.now())
))
```

- `Message.hrtime()` calls `process.hrtime()` → `(seconds, nanoseconds)` tuple
- `Message.now()` calls `Date.make()->Date.getTime` → milliseconds since epoch
- Result format: `"1709913245123-000456789"` (ms-ns)
- This is a **string** stored as the DynamoDB sort key

### Storage (DynamoDB)

- Table: partition key `id` (aggregate ID, type `S`), sort key `sequenceNr` (type `S`)
- Append uses `batchWriteWithRetries` — unconditional `PutItem` operations
- The `_sequenceNr` integer parameter is **ignored** in `EventLogStorage_DynamoDb_Runtime.res`:

```rescript
let append = table =>
  (_sequenceNr, _id, jsons) =>   // _sequenceNr unused
    jsons->Array.map(toPutRequest)->toTable(table.name)->batchWriteWithRetries
```

### Aggregate Command Handling

In `Aggregate_Callback.res`, the flow is:

1. **Replay** all events for the aggregate, counting them: `(state, sequenceNr)`
2. **Process** commands through behavior, generating new events
3. **Append** with `Ops.eventLog.append(sequenceNr, id, generatedEvents')`
4. The `sequenceNr` is passed but never checked — append always succeeds

### Replay Ordering

Events are replayed via DynamoDB `Query` with `consistentRead: true`. DynamoDB returns items sorted by sort key (`sequenceNr`). Since timestamps are lexicographically ordered, events come back in chronological order.

### In-Memory Adapter

Also ignores the `_seqNr` parameter. Events are appended to an array; ordering is by insertion order.

### DCB EventLog (for comparison)

The DCB EventLog uses a different approach with `appendCondition`:
- Position identifiers: `{timestamp}-{uuid}` format
- Supports a check-then-act pattern: read matching events after a position, then append only if none found
- Still not truly atomic (race between read and write)

---

## SQS FIFO Ordering Analysis

The CommandTopic is implemented on AWS as an SQS FIFO queue. Understanding its ordering guarantees is critical to assessing whether optimistic locking is truly needed.

### How It Works

1. **MessageGroupId = Aggregate ID**: When publishing a command, `Util_SQS_Runtime.res` sets `messageGroupId: commandJson.id` — the aggregate ID. Each aggregate gets its own message group.

2. **FIFO guarantee per message group**: SQS FIFO delivers messages in order within a message group and only releases the next batch after the previous batch is successfully processed (deleted) or times out.

3. **Deduplication scope**: `MessageGroup` — deduplication is per-aggregate, not per-queue.

4. **Lambda processing**: `Aggregate_Callback.handleCommands` groups the batch by aggregate ID and processes each aggregate with `Effect.all(..., {"concurrency": "unbounded"})` — different aggregates run in parallel, but commands for the same aggregate are processed sequentially via `Array.reduce`.

### Is Ordering Really Guaranteed?

**Within a single Lambda invocation**: Yes. Commands for the same aggregate arrive in the same batch and are processed sequentially. The replay happens once at the start, all commands fold through the state, and the resulting events are appended in one batch. No concurrency issue exists here.

**Across Lambda invocations**: This is where the guarantee becomes nuanced.

SQS FIFO ensures that within a message group, only one batch is in-flight at a time. The next batch for Aggregate-A is not delivered until the previous batch's messages are deleted (Lambda success) or become visible again (Lambda failure + visibility timeout). This means:

- **Normal operation**: Commands for the same aggregate are serialized across invocations. No two Lambda invocations process the same aggregate concurrently. **Ordering is guaranteed, and no concurrent write conflict can occur.**

- **Failure + retry**: If a Lambda invocation fails and messages re-appear after the visibility timeout (180s), they are re-delivered. The same commands are re-processed against a potentially different state (if a previous partial write occurred). With the current timestamp-based append, this could produce duplicate events.

### Scenarios Where SQS FIFO Ordering Breaks Down

#### Scenario 1: Multiple Command Sources

If commands for the same aggregate are published from **multiple SQS FIFO queues** (e.g., multiple plugins sending commands to the same aggregate via different CommandTopics), each queue's MessageGroupId guarantee is independent. Two Lambda invocations — one per queue — can process the same aggregate concurrently.

**Does this happen today?** Potentially. If an aggregate's CommandTopic receives commands from an Extension or cross-plugin communication, the commands may arrive through different queues.

#### Scenario 2: Lambda Failure with Partial Write

If a Lambda invocation successfully appends events to DynamoDB but crashes before acknowledging the SQS messages (before the SDK deletes them from the queue), the same commands are re-delivered. The aggregate replays the newly written events, processes the commands again, and may generate duplicate events — or different events if the behavior is non-deterministic based on state.

With timestamp-based sequenceNr, the duplicate events get different timestamps and both persist. With integer sequenceNr + conditional writes, the duplicate append would fail (conflict detected), which is the desired behavior.

#### Scenario 3: Visibility Timeout Race

If a Lambda invocation runs longer than the visibility timeout (180s), SQS makes the messages visible again while the first invocation is still running. A second invocation picks up the same batch. Both process the same aggregate concurrently.

**Mitigation**: The 180s timeout should be well above the typical processing time. But for aggregates with very long event histories (large replays), this is a risk.

#### Scenario 4: Future Architecture Changes

Relying solely on SQS FIFO ordering ties the concurrency model to the transport mechanism. If the CommandTopic is ever implemented on a different technology (e.g., EventBridge, direct invocation, HTTP), the ordering guarantee would need to be re-evaluated. Optimistic locking at the storage level is transport-agnostic.

### Assessment

SQS FIFO provides strong ordering guarantees under normal operation for the single-CommandTopic-per-aggregate case. However, optimistic locking is still valuable as:
- A **safety net** for edge cases (failure + retry, timeout races, multiple command sources)
- A **transport-agnostic** correctness guarantee
- A **data integrity safeguard** that doesn't rely on infrastructure behavior

---

## Problems with Current Approach

### 1. No Concurrency Protection

Although SQS FIFO serializes commands in the common case, edge cases (see above) can lead to concurrent writes. Two invocations processing commands for the same aggregate can both replay the same events, make the same decision, and both append successfully — producing duplicate or conflicting events.

### 2. Silent Data Corruption

Because appends never fail due to conflicts, there is no signal that something went wrong. The aggregate's invariants can be violated without any error.

### 3. Timestamp Collisions (Theoretical)

Two events appended in the same nanosecond within the same Lambda invocation would produce the same sort key, causing a silent overwrite. Extremely unlikely with `process.hrtime()` but not impossible under high load with batch appends.

### 4. No Replay Count Guarantee

After replay, the aggregate knows it saw N events. But in failure scenarios, another invocation may have added events between replay and append. The aggregate has no way to detect this.

### 5. Duplicate Events on Retry

When a Lambda fails after writing events but before acknowledging SQS, the re-delivered commands produce new events with different timestamps. Both sets persist — the event log contains duplicates with no mechanism to detect or prevent them.

---

## Target State: Integer Sequence Numbers with Optimistic Locking

### Design

1. **Sort key**: Change from timestamp string to zero-padded integer string (e.g., `"000000001"`, `"000000002"`)
2. **Append with condition**: Use DynamoDB conditional writes to enforce that the expected next sequence number doesn't already exist
3. **Retry on conflict**: When a `ConditionalCheckFailedException` occurs, re-replay and re-process the command

### Retry Logic

```
1. Replay events → state + sequenceNr (N)
2. Process commands → new events
3. Append events starting at sequenceNr N+1 with condition
4. If ConditionalCheckFailedException:
   a. Re-replay events → new state + new sequenceNr (M where M > N)
   b. Re-process commands against new state
   c. Retry append from M+1
5. Max retries: 3 (configurable)
```

Note: With SQS FIFO serialization, conflicts should be extremely rare in practice. The retry logic exists as a safety net, not as a hot path.

---

## Advantages of Real Sequence Numbers

### 1. True Optimistic Locking
Concurrent writes to the same aggregate are detected and retried. Aggregate invariants are preserved even in edge cases.

### 2. Deterministic Event Order
Integer sequence numbers provide an unambiguous, gap-free ordering within each aggregate.

### 3. Efficient Replay from Position
`sequenceNr > N` queries become efficient with integer sort keys — useful for partial replays and snapshotting.

### 4. Conflict Visibility
Failed appends produce explicit errors that can be logged, monitored, and alerted on.

### 5. Simpler Mental Model
Developers can reason about events as an ordered sequence (1, 2, 3, ...) rather than timestamps.

### 6. Idempotent Retry Protection
If a Lambda retries commands that were already partially written, the conditional write on the expected sequenceNr detects the conflict and triggers a re-replay, preventing duplicate events.

---

## Write Strategy: Adaptive Conditional Append

### The Problem

DynamoDB offers three write mechanisms, each with trade-offs:

| Method | Supports Conditions | Cost | Atomicity | Max Items |
|--------|---------------------|------|-----------|-----------|
| `PutItem` | Yes (`ConditionExpression`) | 1 WCU per 1KB | Per-item | 1 |
| `BatchWriteItem` | No | 1 WCU per 1KB | None (partial failures possible) | 25 |
| `TransactWriteItems` | Yes | 2 WCU per 1KB | All-or-nothing | 100 |

### Adaptive Strategy

Choose the write method based on the number of events to append:

#### Single event (most common case)

Use a single **`PutItem`** with `ConditionExpression`:

```
PutItem(
  item: event with sequenceNr = N+1,
  conditionExpression: "attribute_not_exists(sequenceNr)"
)
```

- Cost: **1 WCU** per 1KB — same as current unconditional writes
- No cost penalty at all compared to the current approach
- Simplest implementation
- Atomic by nature (single item)

#### Small batch (2-5 events)

Use multiple **`PutItem`** calls with conditions, executed sequentially:

```
PutItem(item: event N+1, condition: "attribute_not_exists(sequenceNr)")
PutItem(item: event N+2, condition: "attribute_not_exists(sequenceNr)")
...
```

- Cost: **1 WCU per item** — same as current approach
- The condition on the first PutItem is the critical gate: if it succeeds, no other writer has claimed sequenceNr N+1 for this aggregate. SQS FIFO ensures no concurrent invocation is processing the same aggregate, so subsequent PutItems are safe.
- If the first PutItem fails (conflict), none of the subsequent writes execute — no partial state.
- Partial failure after the first PutItem is theoretically possible (Lambda crash between writes), but:
  - The condition on each item prevents overwriting if retried
  - Gap-free sequence numbers make partial writes detectable during replay (if replay sees N+1 and N+2 but not N+3, the append was incomplete)

#### Larger batch (6+ events)

Use **`TransactWriteItems`**:

```
TransactWriteItems([
  Put(item: event N+1, condition: "attribute_not_exists(sequenceNr)"),
  Put(item: event N+2, condition: "attribute_not_exists(sequenceNr)"),
  ...
])
```

- Cost: **2 WCU per item** — double the normal cost
- All-or-nothing atomicity — no partial writes
- The threshold of 6 is pragmatic: below this, sequential PutItems are cheaper and the partial-write risk is acceptable given SQS FIFO serialization

### Why This Combined Approach Makes Sense

1. **Cost efficiency**: The vast majority of aggregate commands produce 1-3 events. Using PutItem for these means **zero cost increase** over the current unconditional writes. Only batches of 6+ events (rare) pay the 2x TransactWriteItems cost.

2. **SQS FIFO as primary serialization**: Since SQS FIFO already prevents concurrent processing of the same aggregate in the normal case, the conditional write is a safety net, not a contention mechanism. Sequential PutItems for small batches are safe because the SQS guarantee means no other writer is active.

3. **Progressive safety**: Single PutItem gives per-item condition checking (conflict detection). Sequential PutItems for small batches give conflict detection on the first item. TransactWriteItems for large batches gives full atomicity. The safety level scales with batch size and the associated risk of partial failure.

4. **Simple implementation**: The adapter can select the strategy with a straightforward threshold check:

```rescript
let appendWithCondition = (table, sequenceNr, id, events) =>
  switch events->Array.length {
  | 0 => Effect.succeed(Ok())
  | 1 => putItemConditional(table, events[0])
  | n if n <= 5 => putItemsSequentialConditional(table, events)
  | _ => transactWriteConditional(table, events)
  }
```

### Cost Impact Analysis

Assuming a typical workload distribution:

| Batch Size | Frequency | Current Cost | New Cost (Adaptive) | New Cost (TransactWriteItems only) |
|------------|-----------|-------------|---------------------|------------------------------------|
| 1 event | ~70% | 1 WCU | 1 WCU (PutItem) | 2 WCU |
| 2-5 events | ~25% | 2-5 WCU | 2-5 WCU (PutItems) | 4-10 WCU |
| 6+ events | ~5% | 6+ WCU | 12+ WCU (Transact) | 12+ WCU |

**Weighted average cost increase**:
- Adaptive strategy: ~**5% increase** (only large batches pay extra)
- TransactWriteItems-only: ~**100% increase** (everything pays double)

The adaptive approach is dramatically cheaper for the typical event sourcing workload where most commands generate a single event.

---

## Consequences and Risks

### 1. Sort Key Format Change

- Current: string timestamp (`"1709913245123-000456789"`)
- Target: zero-padded integer string (`"000000001"`)
- **Migration required** for existing data — cannot mix formats in the same table
- Options:
  - **New table**: Deploy new tables, migrate events offline. Clean but requires downtime or dual-write period.
  - **In-place migration**: Script to renumber events per aggregate. Risky — must ensure no writes during migration.
  - **Versioned format**: Support both formats during transition. Complex.

### 2. Retry Complexity

- Commands must be re-processable (idempotent behavior functions) — this is already the case since behaviors are pure functions of `(state, command) → events`
- Retry loop adds latency under contention — but contention on a single aggregate should be extremely rare given SQS FIFO serialization
- Maximum retry count prevents infinite loops
- Recommendation: retry within the Lambda handler (not via SQS re-delivery) for fast recovery

### 3. Partial Write Recovery (Sequential PutItems)

For small batches using sequential PutItems, a Lambda crash between writes leaves a partial event batch. Recovery options:
- **On re-replay**: The aggregate sees fewer events than expected for the command. The SQS re-delivery causes the command to be re-processed. The conditional PutItem on N+1 fails (already exists), triggering a re-replay that picks up the partially written events. The command is re-processed from the new state, and missing events are written with new sequence numbers.
- **Gap detection**: If replay encounters a gap in sequence numbers, it could flag a warning. However, gaps shouldn't occur in normal operation — they only indicate a bug or incomplete write.

### 4. In-Memory Adapter Changes

The in-memory adapter must also enforce optimistic locking to ensure behavioral parity with the AWS adapter. This means checking that the expected sequence number matches before appending.

### 5. Impact on Event Encoding

`EventLog_Operations.encodeEvent'` currently generates the timestamp-based sequenceNr. This must change to accept the sequence number from the caller:

```rescript
// Current: sequenceNr generated internally from timestamp
("sequenceNr", JSON.Encode.string(hrtimeToString(...)))

// Target: sequenceNr provided as parameter
("sequenceNr", JSON.Encode.string(seqNr->Int.toString->String.padStart(9, "0")))
```

### 6. appendStream Changes

`appendStream` in the DynamoDB runtime currently increments a local counter but doesn't enforce conditions. It would need the same conditional write logic, using sequential PutItems since stream items arrive one at a time.

### 7. No Impact on DCB EventLog

The DCB EventLog uses a separate storage pattern with its own position system. This change is scoped to the aggregate-based EventLog only.

---

## Effort Estimate

### Core Changes (Small)

| File | Change | Effort |
|------|--------|--------|
| `Message.res` | Remove `hrtime`/`hrtimeToString` (or keep for backward compat) | Trivial |
| `EventLog_Operations.res` | Accept sequenceNr as parameter, format as padded int | Small |
| `EventLog.res` | No type change needed (`append` already takes `int`) | None |
| `Aggregate_Callback.res` | Add retry loop around replay+process+append | Medium |

### AWS Adapter Changes (Medium)

| File | Change | Effort |
|------|--------|--------|
| `EventLogStorage_DynamoDb_Runtime.res` | Implement adaptive append (PutItem / sequential PutItems / TransactWriteItems) | Medium |
| `EventLogStorage_DynamoDb_Runtime.res` | Handle `ConditionalCheckFailedException` → return conflict error | Small |
| `EventLogStorage_DynamoDb.res` | No change (table structure stays the same, sort key is already `S`) | None |
| `Util_DynamoDb_Runtime.res` | Add `transactWriteItems` and conditional `putItem` helpers | Small |
| `rescript-aws-sdk` | Add TransactWriteItems bindings if not present | Small |

### In-Memory Adapter Changes (Small)

| File | Change | Effort |
|------|--------|--------|
| `EventLogStorage_InMemory.res` | Check expected sequenceNr before append, return conflict error | Small |

### Testing (Medium-Large)

| Area | Change | Effort |
|------|--------|--------|
| Aggregate unit tests | Test retry behavior on conflict | Medium |
| In-memory adapter tests | Test conflict detection | Small |
| E2E tests | Verify end-to-end with concurrent commands | Medium |
| AWS integration test | Verify adaptive write strategy works | Medium |

### Data Migration (Large, if needed)

| Task | Effort |
|------|--------|
| Write migration script to renumber existing events | Medium |
| Test migration on staging data | Medium |
| Plan and execute production migration | Large (operational) |

### Total Estimate

- **Code changes**: ~2-3 days
- **Testing**: ~2-3 days
- **Data migration** (if existing data): ~2-4 days including planning and execution
- **Total for greenfield** (no existing data to migrate): ~4-6 days
- **Total with migration**: ~6-10 days

---

## Recommendation

Implement real integer sequence numbers with optimistic locking using the **adaptive write strategy**:
- PutItem with condition for single events (most common, no cost increase)
- Sequential PutItems with conditions for small batches (2-5 events, no cost increase)
- TransactWriteItems for larger batches (6+, 2x cost but rare)

The SQS FIFO queue already provides strong serialization in the normal case. Optimistic locking adds a transport-agnostic safety net for edge cases (failure + retry, timeout races, multiple command sources) without penalizing the common path.

The aggregate callback already passes the sequence number (just unused), and the retry logic fits naturally into the existing Effect-based pipeline. Conflicts should be extremely rare in practice.

For migration strategy: if existing production data exists, prefer creating new tables and migrating events offline with a renumbering script. This avoids format-mixing complexity.

Implementation order: in-memory adapter (fast test feedback) → core encoding changes → AWS adapter (adaptive write) → retry logic in aggregate callback.
