# Plan: Atomic DCB Append on DynamoDB

## Problem

`DcbEventLogStorage_DynamoDb_Runtime.append` performs the consistency check as a `read` followed by a separate `BatchWriteItem`. The two requests are not connected, so concurrent writers can both pass the check and both succeed, silently violating the DCB consistency boundary. Tag queries also hit GSIs (always eventually consistent), which widens the race window beyond network RTT.

Full background, race interleaving, and option sketches live in [docs/analysis/dcb-dynamodb-consistency-check.md](../analysis/dcb-dynamodb-consistency-check.md). Read that first — this plan is the implementation track for the recommended option (**Option C — hybrid head-pointer + per-tag fences**).

The fix replaces the read+BatchWriteItem pair with a single `TransactWriteItems` whose `ConditionExpression`s are evaluated atomically against the same state the events commit against. The slice's existing 3-retry loop in `StateChangeSlice_Callback` becomes meaningful for the first time.

## Goals

- **Correctness**: every successful `append` either commits all events atomically or fails with `Error("Conflict: …")`. No silent invariant violations.
- **No second read on the append path**: rely on the `headPosition` already produced by the slice's decision-model read.
- **Minimum incremental cost in the common single-tag case**: one extra write (head pointer update) per command, regardless of event count.
- **Honest behaviour for tagless queries**: either reject at slice-build time or document the eventual-consistency caveat — no silent unsoundness.
- **No schema migration of existing tables required**: lazy-init sentinels via `attribute_not_exists`.

## Non-goals

- Replacing the GSI-based read path on `read` / `readStream`. The decision-model read can stay eventually consistent — only the *write-side* condition needs to be atomic.
- Changing `Reventless.DcbTag.appendCondition` shape or anything in `reventless-core`. The fix is adapter-internal.
- Strong consistency for `read` queries themselves. (Possible follow-up; not required for correctness of `append`.)

## Approach

Each DCB consistency boundary is fenced by one or more **sentinel items** stored in the same DynamoDB table as the events:

- **Head pointer** for single-tag queries: `{id: "<tag.key>:<tag.value>", position: "HEAD", lastPosition: <pos>}`
- **Per-tag fence** for multi-tag queries: `{id: "fence#<tag.key>:<tag.value>", position: "FENCE", lastPosition: <pos>}`

A successful `append` issues a `TransactWriteItems` containing:

- one `Put` per new event (existing item shape, no change),
- one `Update` per relevant sentinel: `SET lastPosition = :new` with `ConditionExpression = attribute_not_exists(lastPosition) OR lastPosition <= :after`.

If any condition fails, the whole transaction aborts with `TransactionCanceledException` → mapped to `Error("Conflict: …")` → `StateChangeSlice` retries from the decision-model read.

Position generation moves into the transaction context: a single base position is produced per call, and event positions derive from it via `generatePositionForBatch`. The same base position becomes the new `lastPosition` on each sentinel.

## Steps

### Step 1 — Audit current callers and lock down the contract

- Re-read `DcbEventLog_Adapter.operations.append` signature; confirm no caller depends on partial commits.
- Confirm `StateChangeSlice_Callback.handleSingleCommand` is the only producer of `appendCondition` in the framework.
- Inventory tagless `appendCondition.query` cases in `examples/online-shop-dcb`. If any exist, decide between (a) rejecting at build time, (b) documenting the caveat. Default: (a).

### Step 2 — Sentinel item layout & helpers

File: `reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res`

- Add `sentinelKey: (~kind: [#Head | #Fence], tag: DcbTag.tag) => dict<JSON.t>` returning the `{id, position}` key.
- Add `buildConditionUpdate: (~sentinelKey, ~newPosition, ~after: option<string>) => TransactWriteItems.update` producing the conditional `Update`.
- Decide kind: `#Head` when the query is a single-tag query collapsing to one partition tag; `#Fence` for multi-tag queries. Carry the choice through `append`.

### Step 3 — Replace `append` with `TransactWriteItems`

Same file. Drop the `read(...)` precondition entirely. New flow:

1. Compute `basePosition = generatePosition()`.
2. Map events → put items (existing `toItem`).
3. From `cond.query` derive the sentinel updates (Step 2 helpers).
4. Build `TransactWriteItems` payload (`Puts ++ Updates`). Cap check: `eventCount + sentinelCount ≤ 100`. If exceeded, fail fast with a clear error.
5. Send via `Effect.tryPromise` with the existing retry schedule, catching `TransactionCanceledException` → `Error("Conflict: ${reasons}")`. All other errors → `Error(message)`.
6. On success → `Ok(basePosition)`.

### Step 4 — Position generation

- Keep `generatePositionForBatch(basePosition, idx)` for event item positions.
- Sentinel `lastPosition = basePosition` (last event of this batch lexically sorts under it via the `-NNN` suffix; comparisons in `ConditionExpression` use `<=` which matches both shapes).
- Decide on a tiebreaker strategy: today's `${ms}-${uuid}` is fine for the conditional check (UUID disambiguates same-ms writers) but the analysis flagged it as a smell. Out of scope for correctness of *this* plan, but note it for a follow-up.

### Step 5 — Tagless query handling

- In `append`, when `cond.query` produces zero sentinel updates (tagless or event-type-only fence), fail with `Error("Conflict check on tagless query is not supported on DynamoDB")` unless explicitly opted out.
- Detect this earlier where possible — at slice-build time inside `StateChangeSlice_Builder` if the query schema is statically known to be tagless. If not statically detectable, runtime error is acceptable.

### Step 6 — Drop dead code

- Remove the now-unused `read(...)`-as-conflict-check path inside `append` and any helpers that exist only to support it.
- Keep `read` and `readStream` for the decision-model path (slice still uses them).

### Step 7 — Update / write tests

- Existing GWT slice tests should keep passing (they exercise the slice's retry loop, which is now genuinely meaningful).
- New adapter-level test: two parallel `append` calls with overlapping tags — exactly one should succeed; the other should return `Error("Conflict: …")`. Run against `dynamodb-local` if the workspace already has it; otherwise use the in-memory adapter parity test as a baseline and add an AWS-only integration test gated on the `aws-integration` job.
- Test: append with `eventCount + sentinelCount > 100` returns a clear validation error before hitting DynamoDB.
- Test: tagless `appendCondition` returns the explicit unsupported error.

### Step 8 — Independent fix: chunk `BatchWriteItem` at 25 items

This is unrelated to consistency but flagged by the same review. Update `Util_DynamoDb_Runtime.batchWriteWithRetries` to chunk inputs into 25-item batches before the first send. Affects `QueryDb` writes too. Land in the same PR or a separate one — implementer's choice.

### Step 9 — Documentation

- Update `docs/guides/aggregate-vs-dcb-decision-guide.md` (or the DCB component doc) with one paragraph: "Append on DynamoDB is now atomic via TransactWriteItems; conflicts are surfaced as `Error("Conflict: …")` and retried up to 3 times by `StateChangeSlice`."
- Cross-link from the analysis document to this plan.
- Once merged, move this plan to `docs/plans/done/` via `git mv`.

## Open questions

- **Sentinel proliferation on high-cardinality tags**: every distinct tag value gets a sentinel item. For `productId` with millions of products, that's millions of sentinel items. Acceptable (DynamoDB scales fine; storage cost is trivial), but worth noting.
- **Sentinel lifecycle**: sentinels are never deleted. If a tag becomes garbage, its sentinel lingers. Acceptable for now; revisit if it becomes a cost issue.
- **Mixed single+multi-tag queries**: a single command may produce events whose tags fence partly via head pointer and partly via per-tag fences. The simplest rule is "always use `#Fence`" — head pointer becomes a pure optimisation we apply only when the query has exactly one tag and produces events with exactly that tag. Decide during Step 2.
- **`StateChangeSlice` retry budget**: 3 retries is fine under low contention but may be too few under heavy contention with real conflicts. Out of scope here; flag for a separate tuning pass.

## Out of scope (recorded for follow-up)

- Strong-consistency reads on the decision-model path (single-tag base-table queries could pass `consistentRead: true`).
- Replacing `${ms}-${uuid}` position generation with a monotonic scheme.
- `Scan`-fallback removal for tagless queries on the read path.
- Per-tag write throughput hot-spotting analysis.

## Status

Implemented (2026-05-08). Pending merge.

### Audit decisions

- **Tagless rejection (Step 1)**: runtime error in `append` with explicit message. Build-time check deferred — requires deeper schema introspection. All five example DCB slices have at least one tagged field, so no current example breaks.
- **Sentinel kind (Step 2)**: always per-individual-tag-value fence. No separate head-pointer fast path. Sentinel id = `fence#<tagKey>:<tagValue>`, sort key = `"FENCE"`. Stored in the same DynamoDB table as events but with a distinct id prefix (no read-side filtering needed).
- **BatchWriteItem chunking (Step 8)**: deferred to a follow-up plan. Out of scope for the consistency fix.
- **Tests (Step 7)**: unit-level against new helpers and transact-items input shape. No `dynamodb-local` in workspace; AWS integration testing follow-up. Existing slice GWT tests run against the in-memory adapter and continue to cover end-to-end retry behaviour.
- **Error classification**: `DynamoDb_Error.classify` did not previously recognise `TransactionCanceledException`. Now handled — cancellation reasons of `ConditionalCheckFailed` map to `StaleState(...)`; `TransactionConflict` / `ProvisionedThroughputExceeded` / `ThrottlingError` map to `Transient(...)`.

### What landed

- [`DynamoDb_Error.res`](../../reventless/reventless-aws/src/errors/DynamoDb_Error.res) — added `TransactionCanceledException` classification by inspecting `CancellationReasons[].Code`.
- [`DcbEventLogStorage_DynamoDb_Runtime.res`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res) — replaced `read + BatchWriteItem` in conditional `append` with a single `TransactWriteItems` carrying:
  - one `Put` per event,
  - one `ConditionCheck`-style `Update` per query tag (`SET lastPosition = :new` if `attribute_not_exists(lastPosition)` or `lastPosition <= :after`),
  - one unconditional `Update` per event-only tag (so future readers detect the bump).
  - Tagless conditions and >100-item transactions return clear errors *before* any AWS call.
- [`tests/DcbEventLogStorage_DynamoDb_RuntimeTest.res`](../../reventless/reventless-aws/tests/DcbEventLogStorage_DynamoDb_RuntimeTest.res) — 18 unit tests covering helper correctness + validation gates.

### Tests run

- `reventless-aws`: 70/70 passing (incl. new runtime suite).
- `reventless-in-memory`: 376/376 passing — slice retry semantics unaffected.
- `online-shop-dcb/catalog`: 41/41 passing.
- `online-shop-dcb/ordering`: 42/42 passing.
- Full monorepo build: clean, zero warnings.

### Post-implementation scorecard

Mapped against the issues listed in [docs/analysis/dcb-dynamodb-consistency-check.md](../../analysis/dcb-dynamodb-consistency-check.md).

#### Consistency

| # | Issue | Status |
|---|---|---|
| 1 | TOCTOU race on read-then-write | ✅ **solved** — single atomic `TransactWriteItems` |
| 2 | GSI eventually-consistent reads under the conflict check | ✅ **solved** — conflict check no longer reads GSIs at all; the fence is atomic with the event Put |
| 3 | Single-tag base-table read not strongly consistent | ⚠️ **not addressed but irrelevant for safety** — the slice's decision-model read is still EC, but missed events trigger fence conflicts → retry, never silent corruption |
| 4 | `Scan` fallback as a basis for consistency | ✅ **rejected** — tagless conditions return `Error("DCB append: tagless conditions are not supported…")` *before* any AWS call |
| 5 | Position ordering with `ms+uuid` ties | ⚠️ **not a correctness issue under the new design** — fence comparison is anchored to what the slice observed, not to global ordering |

#### Performance

| # | Issue | Status |
|---|---|---|
| 1 | Two reads per command, 3+ round-trips | ✅ **solved** — append no longer re-reads; one decision-model read + one transactional write |
| 2 | `read()` materialises the full set to test emptiness | ✅ **solved** — gone entirely |
| 3 | `BatchWriteItem` 25-item limit not chunked | ❌ **deferred** — still a real bug for `appendUnconditional` and `QueryDb`. Conditional `appendConditional` is now capped at 100 (TransactWriteItems limit) and surfaces a clear error instead of `ValidationException`. |
| 4 | Retries multiply work (~4× a clean append) | ✅ **partially solved** — now ~2× (one extra decision-model read on conflict). The duplicate read inside `append` is gone. |

### New concerns introduced by the fix

These were not in the original analysis but are inherent to the per-tag-value fence design and worth recording:

1. **WCU cost per write roughly doubles**. `TransactWriteItems` charges 2 WCU per item vs `BatchWriteItem`'s 1 WCU; we also pay for each fence Update. A 1-event/1-fence command goes from 1 WCU to 4 WCU. Real cost on hot tables — surface in production sizing.
2. **Hot-tag write contention**. Every writer touching a popular tag value now serializes through that tag's fence partition. Throughput on a single popular tag is bounded by single-partition WCU. This was *implicit* before (silent races); now it's *explicit* (correct serialization with conflict retries).
3. **Over-fencing false positives**. Per-individual-tag-value fences mean: if writer A's command is `{tag T1, eventTypes E1}` and writer B produces an event tagged T1 (but for a different consistency boundary), B's commit bumps T1's fence and A's concurrent commit fails — even though A's query wouldn't semantically have matched B's event. False-positive conflict → retry → eventually correct. The trade is "extra retries vs silent corruption" and the right call for DCB.
4. **Storage**: one sentinel item per distinct tag value, never garbage-collected. Acceptable; flagged in this plan's Open Questions.

### Bottom line

The **invariant violations** (the things that could silently corrupt state) — gone. The **dominant performance regression** (extra read + scan-based emptiness check) — gone. What remains:

- One correctness-irrelevant smell: `ms+uuid` positions (cosmetic).
- One real perf bug still open: `BatchWriteItem` 25-item chunking (affects unconditional appends and QueryDb).
- One real perf concern carried forward: decision-model reads still hit eventually-consistent GSIs (causes unnecessary fence-conflict retries when GSI is lagging).
- New concerns inherent to per-tag fencing: 2× WCU, hot-tag serialization, over-fencing false positives.

### Deferred follow-ups

Filed in `docs/plans/Backlog/`:

- [`dcb-dynamodb-atomic-append-integration-test.md`](dcb-dynamodb-atomic-append-integration-test.md) — AWS integration test against DynamoDB Local proving atomicity end-to-end, not just shape.
- [`dynamodb-batchwriteitem-25-chunking.md`](../Backlog/dynamodb-batchwriteitem-25-chunking.md) — chunk `BatchWriteItem` payloads at 25 items in `Util_DynamoDb_Runtime`. Affects `appendUnconditional` and `QueryDb`.
- [`dcb-strong-consistency-single-tag-reads.md`](../Backlog/dcb-strong-consistency-single-tag-reads.md) — `queryByPartitionKeyStream` could pass `consistentRead: true`. Reduces unnecessary fence-conflict retries on GSI lag.
- [`dcb-monotonic-position-generation.md`](../Backlog/dcb-monotonic-position-generation.md) — replace `${ms}-${uuid}` with an HLC-style monotonic generator. Cosmetic under the new design but cleaner semantics.

Not yet filed (waiting for production evidence of need):

- **WCU cost / hot-tag observability** — instrument fence write contention; document scaling guidance for high-throughput tag values in the DCB component docs.

The now-unused `read(...)`-based conflict-check inside `append` is already removed in this PR; `read` and `readStream` exports remain for the slice's decision-model path.
