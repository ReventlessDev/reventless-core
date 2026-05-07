# Plan: Chunk `BatchWriteItem` Payloads at 25 Items

**Analysis**: [dcb-dynamodb-consistency-check.md](../../analysis/dcb-dynamodb-consistency-check.md) — Performance issue #3
**Sibling plan**: [dcb-dynamodb-atomic-append.md](../done/dcb-dynamodb-atomic-append.md) — explicitly defers this fix

## Problem

DynamoDB's `BatchWriteItem` API rejects requests with more than 25 items per call (`ValidationException: Member must have length less than or equal to 25`). The current `Util_DynamoDb_Runtime.batchWriteWithRetries` does not chunk inputs — it sends whatever it's given and only retries the `unprocessedItems` returned by the server. A request with 26+ items fails up front before any server-side processing happens, with a generic AWS error rather than a clear chunking message.

Affected call sites today:

- `DcbEventLogStorage_DynamoDb_Runtime.writeEventsWithPosition` (used by `appendUnconditional` — the unconditional / non-DCB path)
- `QueryDbStorage_DynamoDb_Runtime` writes (read-model batch persistence)

The DCB conditional append path is unaffected — it uses `TransactWriteItems` (capped at 100, with explicit pre-call validation).

## Goals

- Any `BatchWriteItem` call with N > 25 items splits into ⌈N/25⌉ batches transparently.
- Each batch retries `unprocessedItems` independently (existing semantics preserved).
- Aggregate result: `Ok(())` if all batches succeed, otherwise `Error(msg)` with a clear summary of which batch failed.
- No API change to callers — the helper signature stays the same.

## Non-goals

- Parallelisation across batches. Sequential is fine; throughput-sensitive workloads should chunk at the call site, not here.
- Replacing `BatchWriteItem` with `TransactWriteItems`. They have different cost / atomicity tradeoffs; stick with batch semantics for non-DCB writes.

## Approach

Update `batchWriteWithRetries` to chunk before its first call. Each chunk runs through the existing retry loop (with `unprocessedItems` re-driven). Aggregate failures across chunks.

```rescript
let chunkSize = 25

let chunkBatchWriteRequests = (
  requests: dict<array<BatchWriteCommand.writeRequest>>,
): array<dict<array<BatchWriteCommand.writeRequest>>> => {
  // Each table's array gets sliced; result is an array of dicts each ≤ 25 items total.
  // Multi-table batches need cross-table accounting since the 25 limit is global.
  ...
}
```

Tricky case: the `BatchWriteItem` 25-item cap is **across all tables** in a single request, not per-table. Today every caller passes a single-table dict, so per-table chunking suffices. Defensive programming: assert single-table input and fail loudly otherwise, until a multi-table use case appears.

## Steps

### Step 1 — Add chunker

Add `chunkBatchWriteRequests` in `Util_DynamoDb_Runtime.res`. Single-table only; throw on multi-table input. Unit-tested.

### Step 2 — Wire into `batchWriteWithRetries`

Replace the single-call path with a `Effect.forEach`-style loop over chunks. Each chunk invokes the current `attempt` recursion (unprocessed-items retry).

Failure semantics:

- If all chunks succeed → `Ok(())`.
- If any chunk fails → `Error(`batchWrite failed at chunk ${idx}/${total}: ${msg}`)` and abort the rest. (Don't continue — partial writes are worse than a clear failure.)

### Step 3 — Tests

Unit tests in `reventless/reventless-aws/tests/Util_DynamoDb_RuntimeTest.res` (new file):

- 0 items → `Ok(())` with no AWS call (defensive — current code also handles this; preserve).
- 1 item → 1 chunk.
- 25 items → 1 chunk.
- 26 items → 2 chunks (25 + 1).
- 100 items → 4 chunks.
- 51 items → 3 chunks (25 + 25 + 1).

These don't need AWS — mock the inner send via a counter. The current file `Util_SQS_RuntimeTest.res` shows the pattern for pure helper tests in this package.

### Step 4 — Audit call sites

Run `grep -rn "batchWriteWithRetries"` across `reventless-aws/`. Confirm no caller relies on the old "fails at >25" behaviour as an implicit guard. Today: 2 call sites, neither does.

### Step 5 — Document

Update [`docs/analysis/dcb-dynamodb-consistency-check.md`](../../analysis/dcb-dynamodb-consistency-check.md) Performance issue #3 to mark resolved. Move this plan to `done/`.

## Open questions

- Should chunks run sequentially or with bounded concurrency (e.g. `Effect.all({"concurrency": 3})`)? Sequential is simpler and avoids DynamoDB throttling spikes. Default to sequential; revisit if profiling shows it as a bottleneck.

## Status

Not started.
