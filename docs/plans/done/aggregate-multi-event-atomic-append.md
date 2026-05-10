# Plan: Atomic Multi-Event Append for Aggregate EventLog

**Analysis**: [aggregate-command-handling-review.md](../../analysis/aggregate-command-handling-review.md) — Correctness §"Multi-event sequential put (count 2–5) is not atomic"

## Problem

[`appendWithCondition`](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res#L42-L54) picks one of three strategies based on event count:

| Count | Strategy | Atomic? |
|---|---|---|
| 1 | Single conditional `PutItem` | ✓ |
| 2–5 | Sequential conditional `PutItem` ([L13-25](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res#L13-L25)) | ✗ |
| 6–100 | `TransactWriteItems` ([L27-40](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res#L27-L40)) | ✓ |

The middle band exists to save WCU (sequential PutItem is 1× WCU per item; `TransactWriteItems` is 2× WCU per item). The cost: a non-transient mid-batch error commits a prefix of the events but reports the whole call as failed.

Recovery analysis (from the review):

- **Transient mid-batch error** (`ThrottlingException`, etc.): storage-level retry replays the whole `appendWithCondition`. The first put now hits `attribute_not_exists(seq)` violation → returns `"conflict"` → Aggregate retries replay-process-append cycle → recovers. ✓
- **Non-transient mid-batch error** (`ValidationException`, `AccessDeniedException`, item-size limit): no retry. The producer sees `Error` for the whole batch; SQS redelivers; the redelivery's replay observes the partial events and `decide` runs against post-event-1 state. **The producer first sees `Rejected`, then `Accepted` for the same `msgId`** — confusing, and only "consistent" if `decide` happens to be deterministic against a partially-applied prefix.

## Goals

- A multi-event command either commits all of its events or none of them.
- The producer's view of the command's outcome matches the durable state: never `Rejected` after a partial commit.
- Cost increase is bounded and documented.

## Non-goals

- Removing the 100-event ceiling. That's a DynamoDB hard limit; events beyond 100 require a different strategy (separate plan if it becomes needed).
- Atomic publish to EventTopic. The DDB Streams outbox already handles that — events become visible iff the row committed.
- Migrating in-memory or non-DynamoDB adapters. They are already atomic by construction.

## Approach

Two viable shapes; pick one.

### Option A — Always use `TransactWriteItems` for count ≥ 2

Simplest. Replace [`appendWithCondition`](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res#L42-L54):

```rescript
let appendWithCondition = (tableName, jsons) => {
  let count = jsons->Array.length
  if count == 0 {
    Effect.succeed(Ok())  // no-op; should never happen given caller checks
  } else if count == 1 {
    // single PutItem path
    Effect.tryPromise(...) ...
  } else if count <= 100 {
    transactWriteConditional(tableName, jsons)
  } else {
    Effect.succeed(Error("max 100 events per command"))  // see sibling plan
  }
}
```

**Cost delta**: 2-event command goes from 2 WCU to 4 WCU (+100%). 5-event command goes from 5 WCU to 10 WCU (+100%). Single-event commands unchanged.

**Pro**: Two code paths instead of three. Atomicity is uniform.
**Con**: WCU cost roughly doubles for the 2–5 band — non-trivial for write-heavy workloads on long aggregates.

### Option B — Sequential PutItem with rollback compensation

Keep the sequential path for count 2–5 but add compensation on mid-batch failure. After event #K commits and event #K+1 fails non-transiently:

1. Issue `DeleteItem` (with `attribute_exists(seq)` to avoid blowing away another writer's work) for events 1..K.
2. Return `Error` with the original cause.

**Pro**: Keeps WCU cost at 1× for events that don't fail.
**Con**: Compensation is its own correctness surface — what if the delete also fails? What if a concurrent writer already moved the head pointer? The fence-based DCB design avoids exactly this kind of multi-step ACK; introducing it here re-creates the same class of bugs we just fixed elsewhere.

**Recommendation: Option A.** Atomicity by construction beats correctness-via-compensation. The +100% WCU on the 2–5 band is the cost of correctness; document it and move on. Workloads that produce > 1 event per command are already accepting the multi-write fan-out.

## Steps

### Step 1 — Replace the count-2-to-5 branch

In [`EventLogStorage_DynamoDb_Runtime.res`](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res):

- Delete `putItemsSequentialConditional` ([L13-25](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res#L13-L25)).
- Update `appendWithCondition` to call `transactWriteConditional` for any `count >= 2`.
- Adjust `appendStream` ([L100-120](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res#L100-L120)) only if it shares the sequential helper — it doesn't, so leave alone.

### Step 2 — Tests

In `reventless/reventless-aws/tests/EventLogStorage_DynamoDb_RuntimeTest.res` (or analogous):

- Mock `TransactWriteCommand.send` to fail mid-batch with a non-transient error (e.g. `ValidationException`).
- Assert: zero items committed (mocked DDB sees no put effect), `Error` returned, no partial state.
- Mock 1, 2, 5, 6, 100, and 101 events. Assert the routing: 1 → PutItem, 2-100 → TransactWriteItems, 101 → rejected up front (covered by sibling plan).
- Verify the `transactWriteConditional` builder produces correct shape for 2..100 items.

Run all `reventless-aws` tests; confirm no regression.

### Step 3 — Update related tests for the WCU change

If any test asserts "1 WCU per event", update it. Most existing tests assert on outcome, not cost; expect minimal noise.

### Step 4 — Document

In [`docs/reventless-components/aggregate.md`](../../reventless-components/aggregate.md), add a "Cost model" subsection:

```
A command that produces:
- 1 event → 1 WCU per event
- 2–100 events → 2 WCU per event (TransactWriteItems)
- > 100 events → rejected; restructure the command
```

Move this plan to `done/`. Update the analysis correctness verdict to mark resolved.

## Open questions

- **Does this affect `EventLog_Operations.append`'s retry budget?** No — `Effect.retry(storageRetrySchedule)` operates on the whole call; whether that call is one PutItem or one TransactWriteItems doesn't change the retry surface. Transient errors still trigger the 5-attempt exp-backoff loop.
- **Should the threshold be configurable?** No. Atomicity isn't a tuning knob; correctness is non-negotiable.
- **What about the `EventLogStorage_DynamoDbStream` adapter?** It shares `EventLogStorage_DynamoDb_Runtime` — same fix, no separate work.

## Status

Done. Implemented Option A:

- `putItemsSequentialConditional` deleted from `EventLogStorage_DynamoDb_Runtime.res`.
- `appendWithCondition` now routes any `count >= 2` through `transactWriteConditional`.
- Extracted `buildTransactItems` as a pure helper (testable shape; mirrors the DCB adapter's `buildEventPuts`).
- Tests in `EventLogStorage_DynamoDb_RuntimeTest.res` cover: shape for 2 items, scaling to 100 items (TransactWriteItems hard limit), empty input, and the existing > 100 fail-fast guard. Full `reventless-aws` test suite (82 tests) green; zero compiler warnings.
- `packages/doc/docs-app/components/aggregate.md` carries a new "Cost model (DynamoDB adapter)" subsection right after the event-count cap admonition.
- Analysis [`aggregate-command-handling-review.md`](../../analysis/aggregate-command-handling-review.md) updated: routing table, caveats, performance table, action backlog, and Summary all reflect the now-uniform atomic path.
