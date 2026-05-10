# Plan: Up-Front 100-Event Cap Validation in Aggregate Append

**Analysis**: [aggregate-command-handling-review.md](../../analysis/aggregate-command-handling-review.md) — Correctness §"`appendWithCondition` does not enforce the `count ≤ 100` cap up front"
**Sibling**: [aggregate-multi-event-atomic-append.md](aggregate-multi-event-atomic-append.md) — depends on this for the unified TransactWriteItems path.

## Problem

[`appendWithCondition`](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res#L42-L54) routes counts > 5 through `TransactWriteItems`, which DynamoDB rejects for > 100 items with `ValidationException`. The error surfaces eventually, but the message is generic ("Member must have length less than or equal to 100") and arrives only after the AWS SDK round-trip.

The DCB equivalent ([`DcbEventLogStorage_DynamoDb_Runtime.res:641-644`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L641-L644)) checks the cap up front with a clear message. The Aggregate path should match.

## Goals

- A command that would produce > 100 events fails immediately with `Error("max 100 events per command")` before any AWS call.
- No silent truncation, no opaque AWS error messages.
- Symmetric with the DCB path's behaviour.

## Non-goals

- Raising the cap. 100 is a DynamoDB hard limit on `TransactWriteItems`.
- Auto-splitting multi-event commands across multiple transactions. Splitting breaks atomicity, which is the entire point of this plan.

## Approach

One-line guard at the top of `appendWithCondition`. Trivial.

```rescript
let appendWithCondition = (tableName, jsons) => {
  let count = jsons->Array.length
  if count > 100 {
    Effect.succeed(Error("EventLog.append: max 100 events per command, got " ++ count->Int.toString))
  } else if count == 1 {
    ...
  } else {
    transactWriteConditional(tableName, jsons)
  }
}
```

The error message format mirrors the DCB path's wording so log search treats them uniformly.

## Steps

### Step 1 — Add the guard

In [`EventLogStorage_DynamoDb_Runtime.res`](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res), at the top of `appendWithCondition`. The error is returned as a string so [`EventLog_Operations.append`](../../reventless/reventless-core/src/components/EventLog/EventLog_Operations.res#L121-L152) wraps it in the standard `Error("EventLog: Error: ...")` envelope.

The guard must run **before** `Effect.retry` — a > 100 event count is not transient.

### Step 2 — Tests

In `reventless/reventless-aws/tests/EventLogStorage_DynamoDb_RuntimeTest.res`:

- 100 events → routed through `TransactWriteItems` (existing path).
- 101 events → returns `Error` containing the string "max 100 events per command", without any AWS SDK call.
- Mock `TransactWriteCommand.send` and assert it is **not** invoked for the 101-event case.

### Step 3 — Document

Add a note in [`docs/reventless-components/aggregate.md`](../../reventless-components/aggregate.md) cost model section: "A single command may produce at most 100 events. Larger fan-outs must be split across multiple commands."

Move this plan to `done/`. Update the analysis to mark resolved.

## Open questions

- **Should the cap be a constant somewhere central?** Both DCB and Aggregate paths use `100`. Consider extracting `Util_DynamoDb.transactWriteItemMax = 100` so a future SDK change (unlikely) is a one-line edit. Low priority; inline literal is fine.

## Status

Done. The guard lives at the top of [`appendWithCondition`](../../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res); coverage is in [`EventLogStorage_DynamoDb_RuntimeTest.res`](../../../reventless/reventless-aws/tests/EventLogStorage_DynamoDb_RuntimeTest.res). The cap is documented in [`aggregate.md`](../../../packages/doc/docs-app/components/aggregate.md) under `decide`. Sibling [`aggregate-multi-event-atomic-append.md`](../Backlog/aggregate-multi-event-atomic-append.md) can now build on the unified-path assumption.
