# Plan: Propagate Streams End-to-End

**Status:** Done
**Created:** 2026-03-05
**Prerequisite:** `docs/plans/effect-error-retry-harmonization.md` (DONE)

---

## Goal

Stop eagerly collecting streams with `Stream.runCollect` at adapter boundaries. Instead, propagate
`Stream.t` through the stack so consumers decide when and how to materialize results. This enables:

- **Per-page retry** inside the stream (each DynamoDB page fetch retries independently)
- **Backpressure** — consumers that need only N items short-circuit pagination via `Stream.take`
- **Memory efficiency** — no need to hold all items in memory before processing

---

## Phase 1: Per-Page Retry Inside Streams — DONE

Added `Effect.retry(DynamoDb_Error.retrySchedule)` inside `queryStream` and `scanStream` so each
individual page fetch is resilient. Removed `Effect.retry` from all `runCollect` call sites.

### Step 1.1 — Add per-page retry to `queryStream` and `scanStream` ✅

**File:** `reventless-aws/src/util/Util_DynamoDb_Runtime.res`

### Step 1.2 — Remove `Effect.retry` from all `runCollect` call sites ✅

| File | Function | Change |
|---|---|---|
| `EventLogStorage_DynamoDb_Runtime.res` | `replay` | Removed `->Effect.retry(...)` |
| `QueryDbStorage_DynamoDb_Runtime.res` | `load` | Removed `->Effect.retry(...)` |
| `QueryEngine_DynamoDb.res` | `queryByTableName` | Removed `->Effect.retry(...)` |
| `QueryEngine_DynamoDb.res` | `scanByTableName` | Removed `->Effect.retry(...)` |

---

## Phase 2: QueryEngine Public API — DONE (Option C)

**Decision:** Option C — keep `promise<array<JSON.t>>` at the public API boundary, use streams
internally with per-page retry. No breaking change for plugin authors.

`queryByTableName` and `scanByTableName` use `queryStream`/`scanStream` (with per-page retry)
internally and collect at the boundary.

---

## Phase 3: QueryDb `load` / `loadStream` — Unify Around Streams — DONE

### Step 3.1 — Add per-page retry to `loadStream` ✅

**File:** `reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res`

`loadStream` now classifies errors with `DynamoDb_Error.classify`, retries per page
with `DynamoDb_Error.retrySchedule`, and maps errors to `QueryDb.storageError`.

### Step 3.2 — Derive `load` from `loadStream` ✅

`load` is now implemented as `loadStream(table)(id)->Stream.runCollect->...->Effect.runPromise`,
eliminating the duplicate code path. Both `load` and `loadStream` now share the same
pagination logic with per-page retry.

### Step 3.3 — Projection.res — No changes needed ✅

`loadAtMost` and `loadAll` already use `loadStream`.

---

## Phase 4: EventLog `replay` — Align with `replayStream` — DONE

### Step 4.1 — Derive `replay` from `replayStream` ✅

`replay` is now implemented as `replayStream(table)(id)->Stream.runCollect->Effect.runPromise`
in both DynamoDB and InMemory adapters.

### Step 4.2 — Updated both adapters ✅

| File | Change |
|---|---|
| `EventLogStorage_DynamoDb_Runtime.res` | `replay` derived from `replayStream`; single code path |
| `EventLogStorage_InMemory.res` | `replay` derived from `replayStream`; single code path |

---

## Phase 5: DcbEventLog Internal Queries — Per-Page Retry — DONE

### Step 5.1 — Per-page retry in stream functions ✅

**File:** `reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res`

Added `DynamoDb_Error.classify` + `DynamoDb_Error.retrySchedule` per-page retry to:
- `queryBySingleTagStream`
- `queryByCompositeTagsStream`
- `scanWithFilterStream`

The eager counterparts (`queryBySingleTag`, `queryByCompositeTags`, `scanWithFilter`) already
benefit from per-page retry via `queryStream`/`scanStream` (updated in Phase 1).

### Step 5.2 — `readStream` scan fallback — Documented ✅

The scan fallback path in `readStream` eagerly collects all sub-streams, sorts, and deduplicates.
This is inherent to the sort requirement and is intentional — cannot be made lazy without a
sorted merge, and scan results have no guaranteed order.

---

## Files Changed

| File | Phase | Change |
|---|---|---|
| `Util_DynamoDb_Runtime.res` | 1.1 | Per-page retry inside `queryStream`/`scanStream` |
| `EventLogStorage_DynamoDb_Runtime.res` | 1.2, 4 | Derived `replay` from `replayStream`; removed redundant retry |
| `EventLogStorage_InMemory.res` | 4 | Derived `replay` from `replayStream` |
| `QueryDbStorage_DynamoDb_Runtime.res` | 1.2, 3 | Per-page retry in `loadStream`; derived `load` from `loadStream` |
| `QueryEngine_DynamoDb.res` | 1.2 | Removed redundant `Effect.retry` from `queryByTableName`/`scanByTableName` |
| `DcbEventLogStorage_DynamoDb_Runtime.res` | 5 | Per-page retry in all stream functions |

---

