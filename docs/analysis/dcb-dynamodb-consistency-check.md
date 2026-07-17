# DCB Append Consistency on DynamoDB — Analysis & Options

**Context**: review of the consistency check that runs when a `StateChangeSlice` writes new events through the AWS DynamoDB `DcbEventLogStorage` adapter. Asks: is the check correct? is it performant?

**Original verdict (pre-2026-05-08)**: not correct under concurrency, and wasteful even in the single-writer case. The original implementation pretended to enforce optimistic concurrency control but in practice could not — the read and the write were independent DynamoDB calls with nothing tying them together (TOCTOU).

**Current verdict (2026-05-10)**: **correct** for the `StateChangeSlice` path. Atomicity is enforced via `TransactWriteItems` carrying per-tag fence sentinels alongside the event puts (landed 2026-05-08, `e95ae856b`). Single-tag base-table reads now use strong consistency (landed 2026-05-09, `89fe39121`). **Performance is acceptable for typical workloads but fragile under hot-tag contention** — per-tag fence partitions are the new throughput ceiling, and `TransactWriteItems` doubles WCU per item. A small set of footguns and follow-up items remain (see [§Current state](#current-state-2026-05-10) and [§Implementation timeline](#implementation-timeline)).

**Update (2026-06-20)**: a fence-scope review found and fixed a class of false-positive `ConditionalCheckFailed` conflicts, and surfaced several further open issues. Both the fix and the full issue inventory live in [dcb-consistency-check-issues.md](dcb-consistency-check-issues.md).

---

## Current state (2026-05-10)

### How it works now

**Producer side — [`StateChangeSlice_Callback.handleSingleCommand`](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L48-L168)**

1. Build a `DcbTag.query` from the command tags.
2. `dcbEventLog.readStream(~query)` → fold into `(decisionState, headPosition, n)`.
3. `Behavior.decide(state, command)` → new events.
4. `dcbEventLog.append(rawEvents, ~condition={query, after: headPosition})`.
5. On `Error`, retry up to `maxRetries = 3` from step 2.

**Storage side — [`DcbEventLogStorage_DynamoDb_Runtime.appendConditional`](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L619-L695)**

The condition is enforced by **per-tag-value fence sentinels** in the same table:

- A fence item per tag value lives at `id="fence#<key>:<value>", position="FENCE", lastPosition=<pos>`. The `id` prefix is distinct from event partition keys (`<key>:<value>`), so event reads never see fence items.
- `appendConditional` builds a single `TransactWriteItems` containing:
  - **One `Put` per new event** (existing event items).
  - **One conditional `Update` per tag in `cond.query`**: `SET lastPosition = :new` gated by `attribute_not_exists(lastPosition) OR lastPosition <= :after` ([`buildConditionalFenceUpdate`](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L564-L584)).
  - **One unconditional `Update` per tag present in new events but not in the query** ([`buildUnconditionalFenceUpdate`](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L589-L601)) — so future readers querying those tags detect us.
- If any condition fails, DynamoDB cancels the transaction → `TransactionCanceledException` → `DynamoDb_Error.StaleState` → `Error("Conflict: …")` → slice retries.
- Tagless conditions ([L637-640](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L637-L640)) and >100-item transactions ([L641-644](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L641-L644)) are rejected up front with clear errors.

**Decision-model read path** — [`executeQueryItemStream`](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L899-L929) picks the read shape from query tags:
- **Single tag** → base-table query with `consistentRead: true` (strong).
- **Multi-tag** → composite GSI query (eventually consistent — DynamoDB constraint).
- **Tagless** → table scan (eventually consistent).

### Correctness assessment

**What works:**

- ✓ **Atomic check-and-act.** The fence updates and event puts ride a single `TransactWriteItems`; conditions are evaluated by the storage engine at commit time. The TOCTOU window is closed.
- ✓ **GSI staleness no longer corrupts.** Even if the slice's GSI read missed a recent event, the *fence* lives in the base table at a known partition key, and `TransactWriteItems` evaluates conditions strongly consistent. A missed-on-GSI write that bumped the fence still fails subsequent conditional updates → retry.
- ✓ **Tagless conditions rejected up front** — there is no DynamoDB primitive that fences event-type-only invariants without a global lock, and the code says so instead of pretending.
- ✓ **>100-item transaction cap surfaced as a clear error** before any AWS call.

**Caveats and footguns:**

- ✓ **`appendUnconditional` no longer bypasses the fence system** (resolved 2026-05-10, [`docs/plans/done/dcb-append-unconditional-fence-bypass.md`](../plans/done/dcb-append-unconditional-fence-bypass.md)). The path now uses `TransactWriteItems` with one unconditional fence bump per event tag, so non-DCB writers (imports, seeding, replay) still keep DCB readers in sync. Trade-off: 2× WCU per item (same as the conditional path) and the same 100-item per-call cap.
- ✓ **Same-millisecond positions tie-break by UUID.** *(Resolved 2026-07-08.)* Was `${ms}-${uuidv4}`; now a Hybrid-Logical-Clock `${ms}-${6-digit counter}-${uuidv4}` ([L6-30](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L6-L30)) — strictly monotonic per call within a warm container. Never a correctness bug (the fence is the consistency primitive, not position); this removes the residual reader/replay-ordering smell. See issue #5 below.
- ⚠ **A query-only fence touch raises false positives for unrelated readers.** If a writer queries `productId=X` to check existence but writes events tagged only with `customerId=Y`, the `productId=X` fence is still bumped (the conditional update commits). Future readers of `productId=X` see the bump and retry once — correct, just wasted work. This is inherent to fence-based OCC, not a bug.

### Performance assessment

**What got better:**

- ✓ **No redundant read on the append path.** The original read-then-write structure is gone; `headPosition` from the slice's decision-model read is the only input the conditional check needs.
- ✓ **Conflict detection is now real.** The 3-retry loop in the slice fires when it should (it previously almost never did, because the check passed even on conflicts).
- ✓ **Single-tag base-table reads opt into strong consistency** ([L910-916](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L910-L916)). Eliminates the avoidable retry when the GSI lags behind a recent commit.

**What's still slow / contention-prone:**

- ⚠ **`TransactWriteItems` costs 2× WCU per item.** A 1-event command with 1 query tag + 0 extra event tags = 2 items = **4 WCU per command**. Multi-tag commands scale linearly. Compared to a non-DCB aggregate write (~1 WCU), DCB is ~4× the per-command write cost — that's the structural DCB tax.
- ⚠ **Hot-tag fence partitions are throughput choke points.** Every command touching tag value `X` serializes through fence `fence#<key>:X` (one DynamoDB partition, ~1000 WCU/sec ceiling, so ~500 transactions/sec per hot fence). Concurrent writers to the same fence trigger `TransactionConflict` (mapped to `Transient` and retried internally). Tags with skewed distribution — e.g. `category=electronics`, `status=active`, a popular product — become global throughput chokepoints. No sharding/buffering mitigation in the current design.
- ⚠ **The unconditional bump for "extra event tags" amplifies fence traffic.** A command writing events tagged `productId=X, customerId=Y, orderId=Z` while only querying `productId=X` writes 4 items (1 event + 3 fence updates = 8 WCU). For events with diverse tags, this scales poorly and eats into the 100-item transaction cap.
- ⚠ **GSI eventual consistency widens the retry window for multi-tag and tagless queries.** Single-tag reads now use strong consistency on the base table, but multi-tag composite GSI ([L919-920](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L919-L920)) and tagless scan ([L923-927](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L923-L927)) still trail by tens of ms. The fence catches the conflict, but the slice pays for an extra retry round-trip when the GSI hasn't caught up.
- ⚠ **`Scan` for tagless query items is expensive on any non-trivial table.** Inevitable for that query shape; at least never used as a consistency primitive (tagless conditions are now rejected).
- ✓ **Decision-model read is now delta-cached per warm instance.** `StateChangeSlice_Callback` keeps a bounded in-process LRU of `(decisionState, readHead)` keyed on the serialised query (shipped 2026-06-20, plan [`dcb-decision-model-projection-cache`](../plans/dcb-decision-model-projection-cache.md)). A warm same-entity command reads only events *after* the cached head (O(delta), typically zero), and a conflict re-seeds from the just-read snapshot so each retry also reads only the delta — the old `(1 + retries)` full reads collapse to one delta read each. Correctness is unchanged: the cache feeds only the *decision*; the conditional append's fence still rejects any stale read → retry. Pays off only with warm-Lambda reuse; a cold instance falls back to the full read. (Per-slice capacity tuning and CloudWatch hit/miss metrics remain as follow-ups — see the plan's Steps 4–5.)

---

## Background — TOCTOU race conditions

**TOCTOU** = **T**ime **O**f **C**heck / **T**ime **O**f **U**se. A class of race condition where code **checks** a condition, then later **uses** the result of that check, but something else can change the underlying state in the gap between the two. The check was true *when you looked*. By the time you act on it, it might not be anymore. Nothing tied the two operations together.

### Classic non-DB example

```python
if os.access("/tmp/file", os.W_OK):  # CHECK: can I write?
    # ← attacker swaps the file with a symlink to /etc/passwd here
    open("/tmp/file", "w").write(data)  # USE: write happens
```

The check said "yes, safe." The use happened on a different state of the world.

### In the DCB append code

```rescript
let readResult = await read(table)(~query=cond.query, ~after=?cond.after)
//   ↑ CHECK: are there any conflicting events?
//
//   ← gap: anything can happen here. another writer can insert events.
//     no lock, no transaction, nothing serialising the two requests.
//
if readResult.events->Array.length > 0 {
  Error("Conflict")
} else {
  await writeEventsWithPosition(table, events, position)
  //   ↑ USE: write goes through unconditionally
}
```

Two concurrent writers `T1` and `T2` interleave like this:

| step | T1                            | T2                            | DB state                      |
| ---- | ----------------------------- | ----------------------------- | ----------------------------- |
| 1    | read → `[]` (no conflict)     |                               | empty                         |
| 2    |                               | read → `[]` (no conflict)     | empty                         |
| 3    | write event A                 |                               | `{A}`                         |
| 4    |                               | write event B                 | `{A, B}` ← invariant violated |

Both writers passed their check. Both wrote. The DCB invariant ("no events match this query after `headPosition`") is now violated, and **no one returned an error**. The retry loop in `StateChangeSlice` only fires on returned errors, so it never even sees the conflict.

### What kills TOCTOU

You eliminate the gap. Either:

- **Lock**: hold a lock across check and use (not viable on DynamoDB — no row locks).
- **Atomic check-and-act**: the check is *part of* the write request, evaluated by the storage engine at write time, against the same state the write commits against. If the check fails, the write is rejected — atomically.

The second is what `ConditionExpression` (single-item) and `TransactWriteItems` (multi-item) give you on DynamoDB. The check moves *into* the write. There is no gap because there is no separate read. That's why all three options below replace the read+BatchWriteItem pair with a conditional write — not because conditional writes are faster, but because they're the only way to close the gap.

### How to spot TOCTOU in code reviews

The shape is always:

1. A read or query that establishes a fact.
2. Logic that branches on that fact.
3. A separate write that depends on the fact still being true.
4. Nothing — no lock, no transaction, no version check on the write — connecting (1) and (3).

If you see that pattern against shared state with concurrent writers, it's a TOCTOU race.

---

## Historical: pre-2026-05-08 implementation

The sections below describe the **original** code that motivated this analysis. The implementation has changed; see [§Current state](#current-state-2026-05-10) above for the post-fix design and [§Implementation timeline](#implementation-timeline) below for what changed when.

### Producer side — `StateChangeSlice_Callback.handleSingleCommand` (pre-fix)
[`reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res`](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res)

1. Build a `DcbTag.query` from the command tags.
2. `dcbEventLog.readStream(~query)` — pull every matching event, fold into `(state, headPosition, n)`.
3. `Behavior.decide(state, command)` → `array<Spec.event>`.
4. Encode events; build `appendCondition = { query, after: headPosition }`.
5. `dcbEventLog.append(rawEvents, ~condition)`.
6. On `Error(_)` retry up to `maxRetries = 3` from step 2.

The producer-side flow is unchanged in the current code — only the storage-side `append` was rewritten.

### Storage side — `DcbEventLogStorage_DynamoDb_Runtime.append` (pre-fix)
Line refs in this section point to the pre-2026-05-08 file layout and no longer match the current source.

```rescript
| Some(cond) =>
    let readResult = await read(table)(~query=cond.query, ~after=?cond.after)
    if readResult.events->Array.length > 0 {
      Error("Conflict: matching events exist after specified position")
    } else {
      let position = generatePosition()
      switch await writeEventsWithPosition(table, events, position, ~partitionTag?) {
      | Ok() => Ok(position)
      | Error(msg) => Error(msg)
      }
    }
```

Where `writeEventsWithPosition` calls
`items -> Array.map(toPutRequest) -> toTable(table.name) -> batchWriteWithRetries`
([L464-480](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L464-L480)). That is `BatchWriteItem` — no `ConditionExpression` support, no transaction.

---

## Correctness problems (pre-fix)

Each item below carries its current resolution status. The numeric ordering is preserved for traceability with prior reviews.

### 1. Read-then-write is not atomic (TOCTOU race) — **critical** [RESOLVED 2026-05-08]

The conflict check and the put are two unrelated DynamoDB requests with nothing serialising them. Two concurrent commands targeting the same consistency boundary can both observe an empty result and both succeed:

```
T1: read  → events = []
T2: read  → events = []        (T1 has not yet written)
T1: write → OK
T2: write → OK                 (DCB invariant violated)
```

The 3-retry loop in `StateChangeSlice` only fires when `append` returns `Error`. With this implementation, the conflicting case usually returns `Ok` from both writers, so retries never trigger and the invariant is silently violated.

This defeats the entire point of the `appendCondition`.

**Resolution:** [`appendConditional`](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L619-L695) replaced the read-then-BatchWriteItem flow with a single `TransactWriteItems` carrying per-event Puts plus per-tag fence Updates with `ConditionExpression`s. The check is now part of the write request, evaluated atomically.

### 2. Tag queries hit GSIs which are always eventually consistent [RESOLVED indirectly]

`queryBySingleTagStream` ([L559](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L559)) and `queryByCompositeTagsStream` ([L601](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L601)) read GSIs.

DynamoDB GSIs **cannot** be read with strong consistency — fundamental product constraint. A just-written event may not appear on the GSI for tens of milliseconds, widening the race window beyond the network RTT.

**Resolution:** GSI staleness no longer corrupts. The fence sentinels live in the **base table** at known partition keys (`fence#<key>:<value>`), and `TransactWriteItems` evaluates conditions strongly consistent against base-table state. A write that landed but hasn't propagated to the GSI yet still bumped its fence, so subsequent conditional updates fail → retry. The slice may pay an avoidable retry round-trip when the GSI lags (a perf cost, not a correctness cost — see [§Current state — Performance assessment](#performance-assessment)).

### 3. Single-tag base-table query does not request strong consistency [RESOLVED 2026-05-09]

`queryByPartitionKeyStream` hits the base table (`id = pk`). This path *could* set `consistentRead: true` but historically didn't, so even single-tag lookups that could have been strongly consistent went through the eventually-consistent default.

Resolved by [`docs/plans/done/dcb-strong-consistency-single-tag-reads.md`](../plans/done/dcb-strong-consistency-single-tag-reads.md): `queryByPartitionKeyStream` now accepts `~strongConsistency` and `executeQueryItemStream` passes `true` on the single-tag branch. GSI-backed branches (multi-tag composite, tagless scan) cannot opt in — DynamoDB rejects `consistentRead: true` on GSIs — so they remain eventually consistent. The fence-based atomic append (issue #1) ensures correctness either way; strong reads on the single-tag path just save the avoidable conflict-retry round trip when the GSI is lagging.

### 4. `Scan` fallback for tagless queryItems [RESOLVED — tagless conditions now rejected]

`scanWithFilterStream` full-table scans, eventually consistent, no condition guard. As a basis for a consistency decision this is unsound and expensive on any non-trivial table.

**Resolution:** `appendConditional` now rejects tagless conditions up front ([L637-640](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L637-L640)) — there is no DynamoDB primitive that fences event-type-only invariants without a global lock. Scans still happen on the *read* path for tagless query items (see [`scanWithFilterStream`](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L827-L897)) but never as a consistency primitive.

### 5. Position ordering breaks ties by UUID [RESOLVED 2026-07-08]

`generatePosition = ${ms}-${uuidv4}` (old format). Same-millisecond writers got arbitrary lexical ordering. Combined with the non-atomic write, "events after `headPosition`" was not a well-defined set across concurrent writers.

**Resolution:** Was never corruption-causing — the fence is the consistency primitive, not position. Fixed the residual cosmetic smell by moving to a Hybrid-Logical-Clock position generator: `${ms}-${6-digit counter}-${uuidv4}` ([L6-30](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L6-L30)). Module-level refs make positions strictly monotonic per call within a warm Lambda container (same-ms calls increment the counter; a forward tick resets it); cross-container same-ms writers still tie-break by UUID, but that no longer perturbs same-container reader/replay ordering. The ms prefix keeps its 13-digit width so old `${ms}-${uuid}` positions still sort by timestamp. Backwards-compatible, no migration. Plan: [`docs/plans/done/dcb-monotonic-position-generation.md`](../plans/done/dcb-monotonic-position-generation.md).

---

## Performance problems (pre-fix)

Each item below carries its current resolution status.

### 1. Two reads per command, three round-trips minimum [RESOLVED 2026-05-08]

`StateChangeSlice` does its own decision-model read ([Callback.res:78](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L78)) and then `append` does the **same query again** before writing. The append-side check is redundant — the slice already paid for that read and knows `headPosition`. If the conflict check were a real precondition on the write request, the second read would not exist.

**Resolution:** The redundant read is gone. `appendConditional` builds `TransactWriteItems` directly from `headPosition`; no append-side query.

### 2. The conflict check materialises the full result set just to test emptiness [RESOLVED 2026-05-08]

The append-side `read(...)` paginated all matching events, decoded, deduped, sorted, then checked `events.length > 0`. For a presence test this should be `Limit: 1` and short-circuit. For hot tag values (e.g. a popular product) this turned a check into a scan.

**Resolution:** No longer applies — the append path no longer reads. The condition is a fence comparison evaluated by the storage engine.

### 3. `BatchWriteItem` 25-item limit is not chunked [REMAINING]

`batchWriteWithRetries` ([Util_DynamoDb_Runtime.res:177](../../reventless/aws/src/util/Util_DynamoDb_Runtime.res#L177)) only re-drives `unprocessedItems`; it does not split inputs into 25-item batches up front. A command producing ≥26 events fails with `ValidationException` before any retry logic kicks in.

**Status:** No longer applies to either DCB append path. As of 2026-05-10, `appendUnconditional` was rewritten on `TransactWriteItems` ([`docs/plans/done/dcb-append-unconditional-fence-bypass.md`](../plans/done/dcb-append-unconditional-fence-bypass.md)) and shares the conditional path's 100-item cap, which is checked up front. Still applies to `QueryDb`'s use of `batchWriteWithRetries`. Backlog plan: [`docs/plans/Backlog/dynamodb-batchwriteitem-25-chunking.md`](../plans/Backlog/dynamodb-batchwriteitem-25-chunking.md).

### 4. Retries multiply work [PARTIAL]

On `Error`, the slice's retry loop re-does the decision-model read. Combined with the duplicate read inside `append`, the cost of a detected conflict was roughly 4× a clean append. The conflicts that actually matter (the ones in §1) bypassed this entirely.

**Status:** The duplicate-read amplifier is gone, and the slice's retry loop is now real (it fires on actual conflicts). The remaining `(1 + retries)` decision-model reads are now **delta reads** on warm instances: the projection cache (shipped 2026-06-20, plan [`dcb-decision-model-projection-cache`](../plans/dcb-decision-model-projection-cache.md)) re-seeds from the just-read snapshot on conflict, so each retry reads only the events the conflicting writer added rather than full history. A cold instance still pays one full read; the worst-case multiplier is gone for hot entities.

---

## Option sketches (historical)

Options considered before the 2026-05-08 fix landed. Kept as audit trail; the implementation took **Option A** (per-tag fence sentinels) — see [§Implementation timeline](#implementation-timeline) for why.

All three options replace the read+BatchWriteItem pair with a single conditional write. The choice is about which DynamoDB primitive backs the condition.

### Option A — `TransactWriteItems` with per-tag fence items

**Idea**: maintain a sentinel item `{id = "fence#<tag.key>:<tag.value>", position = "FENCE", lastPosition = <pos>}` for every tag value that has ever been written. On append, build a `TransactWriteItems` containing:

- one `Put` per new event (the existing items),
- one `Update` per consistency-relevant tag fence: `SET lastPosition = :new` with `ConditionExpression = attribute_not_exists(lastPosition) OR lastPosition <= :after`.

If any condition fails, the whole transaction aborts atomically with `TransactionCanceledException` → return `Error("Conflict")` → existing retry loop kicks in for real this time.

**Sketch**:
```rescript
let buildTransactItems = (events, baseItems, conditionTags, after) => {
  let putItems = baseItems->Array.map(item => Put({tableName, item}))
  let fenceUpdates = conditionTags->Array.map(tag => {
    Update({
      tableName,
      key: {"id": `fence#${tag.key}:${tag.value}`, "position": "FENCE"},
      updateExpression: "SET lastPosition = :new",
      conditionExpression: "attribute_not_exists(lastPosition) OR lastPosition <= :after",
      expressionAttributeValues: {":new": newPos, ":after": after->Option.getOr("")},
    })
  })
  Array.concat(putItems, fenceUpdates)
}
```

**Pros**:
- Real atomicity. No TOCTOU window.
- No second read on the append path — `headPosition` from the slice's decision-model read is the precondition.
- Generalises to multi-tag DCB queries (each tag fence checked independently).

**Cons**:
- 100-item transaction cap → max ~`100 - eventCount` tag fences per command. Realistic for most slices, blocks pathological ones.
- Every event-producing path also needs to update the fence(s) it touches, which doubles writes per fence per command (one event Put + one fence Update). Cheaper than the current second read in almost all cases.
- Fence items must be initialised on first write (the `attribute_not_exists` branch handles this).
- Event-type-only queries (no tags) still need a different mechanism — see Option C.

**Cost model**: 1 transaction = `eventCount + tagFenceCount` write capacity units, ×2 for transactions. Compare to today: 1 Query (≥ 1 RCU, often more) + 1 BatchWriteItem (`eventCount` WCU). For a typical 1-event/1-fence command: 4 WCU vs 1 RCU + 1 WCU. Marginal cost increase, real correctness gain.

### Option B — Per-partition head pointer (single-tag DCB only)

**Idea**: for each partition key (= the derived DCB partition tag, e.g. `productId:abc`), store one head item `{id = pk, position = "HEAD", lastPosition = <pos>}`. Append issues a `TransactWriteItems`:

- `Update` on `(pk, "HEAD")` with `ConditionExpression = lastPosition = :expected` (the slice's `headPosition`),
- `Put` per event.

**Pros**:
- Simplest model. Atomicity for free.
- One additional write per command regardless of event count.
- Strongly consistent reads on the head pointer alone (`GetItem` with `consistentRead: true`) — the decision-model read can be optimised in a second step.

**Cons**:
- Only works when the consistency boundary is exactly **one** tag. Multi-tag DCB (e.g. a query that fences both `customerId` and `productId`) cannot be expressed.
- Reventless DCB queries are inherently multi-tag (`buildQueryFromCommand` produces a `query: array<queryItem>`), so this option is too narrow as the only mechanism — but it is a clean fast path when the query collapses to one tag.

### Option C — Hybrid: head pointer + tag fences

**Idea**: combine the two. The partition-key path uses Option B (cheap, atomic). For multi-tag queries, fall back to Option A's per-tag fences. For tagless event-type-only queries, accept that DCB cannot fence them on DynamoDB without a global lock, and either (a) reject such queries at slice-build time, or (b) document the eventual-consistency caveat and keep the current scan.

**Pros**:
- Best cost in the common single-tag case.
- Real atomicity in the multi-tag case.
- Honest about the tagless case rather than pretending.

**Cons**:
- Two code paths in the adapter, picked from `query` shape.
- Schema migration: tables provisioned today don't have head/fence sentinels. Either lazy-init via `attribute_not_exists` (works) or a one-shot backfill.

---

## Recommendation (historical, partially superseded)

Original recommendation was Option C (head pointer + tag fences). The implementation took the per-tag-fence half (Option A) and skipped the head-pointer fast path — see [§Implementation timeline](#implementation-timeline). Concrete next steps as originally written:

1. Replace `append` with a `TransactWriteItems` implementation. For single-tag queries, target `(pk, "HEAD")`. For multi-tag, build per-tag fences. Drop the second `read(...)` from the append path entirely.
2. Strip the now-dead "conflict check" code from `append`; rely on `TransactionCanceledException` mapped to `Error("Conflict: …")`. The slice's retry loop already handles this correctly.
3. Stop generating positions in app code. Use a single base position per `TransactWriteItems` call (the head pointer's new value) — atomic with the conditional check.
4. Document or reject tagless DCB queries that include event-type-only fences. They cannot be made consistent on DynamoDB without serialising all writes.
5. Independent of the above: chunk `BatchWriteItem` payloads at 25 items in `batchWriteWithRetries` to remove the `ValidationException` ceiling (this also affects `QueryDb`'s use of the same helper).

The in-memory adapter does not have these problems because its append is synchronous against an in-process structure. Worth comparing semantics side-by-side when implementing the fix to ensure `StateChangeSlice` GWT tests are exercising the conflict path the adapter is meant to enforce.

---

## Implementation timeline

### 2026-05-08 — Atomic append (`e95ae856b`)
Plan: [`docs/plans/done/dcb-dynamodb-atomic-append.md`](../plans/done/dcb-dynamodb-atomic-append.md).

Replaced the read-then-BatchWriteItem flow with a single `TransactWriteItems` carrying per-event Puts plus per-tag fence Updates with `ConditionExpression`s. The implementation took **Option A** (per-individual-tag-value fences only) rather than the recommended Option C — the head-pointer fast path was skipped because per-tag fences already cover the single-tag case correctly, and the simplification kept one code path instead of two.

- Per-tag fence sentinels: `id="fence#<key>:<value>", position="FENCE", lastPosition` tracks latest commit.
- Tagless conditions and >100-item transactions return clear errors before any AWS call.
- `DynamoDb_Error` classifies `TransactionCanceledException`: `ConditionalCheckFailed → StaleState`; `TransactionConflict / ProvisionedThroughputExceeded / ThrottlingError → Transient` (retried internally).
- 18 unit tests cover helper shape and validation gates ([`DcbEventLogStorage_DynamoDb_RuntimeTest.res`](../../reventless/aws/tests/DcbEventLogStorage_DynamoDb_RuntimeTest.res)).
- Slice GWT, in-memory adapter, and DCB example tests passed unchanged.

### 2026-05-09 — Strong-consistency single-tag reads (`89fe39121`)
Plan: [`docs/plans/done/dcb-strong-consistency-single-tag-reads.md`](../plans/done/dcb-strong-consistency-single-tag-reads.md).

`queryByPartitionKeyStream` now accepts `~strongConsistency`, and `executeQueryItemStream` passes `true` on the single-tag branch. Eliminates an avoidable fence-conflict retry when the GSI lags. Multi-tag composite GSI and tagless scan branches stay eventually consistent — DynamoDB rejects `consistentRead: true` on GSIs.

### 2026-05-10 — `appendUnconditional` fence-bypass closed
Plan: [`docs/plans/done/dcb-append-unconditional-fence-bypass.md`](../plans/done/dcb-append-unconditional-fence-bypass.md).

`appendUnconditional` now rides the same `TransactWriteItems` primitive as `appendConditional`: per-event Puts plus one **unconditional** fence Update per event tag. Non-DCB writers (imports, seeding, replay) keep the fence sentinels current, so concurrent conditional writers cannot miss their commits. `writeEventsWithPosition` (the `BatchWriteItem`-backed helper) is gone from the DCB log. Same 100-item per-call cap as the conditional path; same error classification. Two new unit tests cover `buildEventPuts` shape and the > 100-item rejection.

### Remaining open items, by priority

Ordered by recommended execution order. Rationale and cost reasoning follow.

| # | Plan | Class | Effort | Runtime $ impact | Why this position |
|---|------|-------|--------|------------------|-------------------|
| 1 | [`dcb-dynamodb-atomic-append-integration-test`](../plans/done/dcb-dynamodb-atomic-append-integration-test.md) | **Verification — P0** | Medium (~3–5 d initial + ongoing CI maint) | Zero prod; marginal CI minutes. | Current correctness story rests on unit tests of `TransactWriteItems` *payload shape*, not real DynamoDB *behaviour*. Also the harness #2 needs. |
| 2a | [`dcb-hot-tag-fence-contention`](../plans/done/dcb-hot-tag-fence-contention.md) §2 (selective bumping) | **Performance — P1 cost-saver** | Small–medium (PPX annotation + filter logic, ~3–5 d) | **Negative** — strips fence writes for `LookupOnly` tags. Per-command WCU drops proportional to LookupOnly tag count. | The cheapest sub-piece of #2. Ships independently of profiling. Pays back on every conditional append. |
| 2b | [`dcb-hot-tag-fence-contention`](../plans/done/dcb-hot-tag-fence-contention.md) §1 (sharding) | **Performance ceiling — P1, profile-gated** | Large (~2–4 w incl. profiling, PPX, sharding, migration) | +N× WCU on hot fences (4-shard = 4× per-fence cost) — but unlocks N× throughput ceiling. Net cost-per-RPS roughly flat. | Structural throughput limit. Gate on profiling — if no fence is actually hot, defer indefinitely. |
| 3 | [`dcb-monotonic-position-generation`](../plans/done/dcb-monotonic-position-generation.md) | **Cleanup — P2 — DONE 2026-07-08** | Tiny (~½ d) | Zero. | HLC generator shipped; strictly monotonic per warm container, backwards-compatible. |
| 4 | [`dynamodb-batchwriteitem-25-chunking`](../plans/Backlog/dynamodb-batchwriteitem-25-chunking.md) | **Operational sharp edge — P2** | Small (~2–3 d) | Zero per-item; eliminates failed-call retry overhead on > 25 batches. | The DCB log no longer uses `BatchWriteItem` (closed 2026-05-10). Plan narrows to `QueryDb`'s read-model batch persistence. |
| 5 | [`dcb-decision-model-projection-cache`](../plans/dcb-decision-model-projection-cache.md) | **Optimization — P3 cost-saver** | Medium–large (~1–2 w) | **Negative** — cache hit replaces O(events) RCU with ~1 RCU + delta. Scales with hit rate × event volume per query. | Pure optimization with no ceiling lift, but the *only* runtime-cost-positive item large enough to pay back its dev cost on hot warm-entity workloads. |

### Sequencing rationale

- **#1 first because the integration test harness is a prerequisite for verifying any further fence-shape change.** Hot-tag sharding (#2b) introduces `ConditionCheck` items spanning multiple fence shards in `TransactWriteItems` — a non-trivial new pattern that we'd want exercised against real DynamoDB before shipping.
- **#2a split out of #2 and promoted because it's a cost-saver, not a cost-payer.** Selective bumping (drop fence writes for `@dcbTag(~consistencyMode=#LookupOnly)` tags) reduces per-command WCU on every write that has auxiliary tags. It needs the PPX-annotation work but not the sharding/profiling apparatus, so it can ship months ahead of #2b. Treat it as a separate PR scoped from the hot-tag plan.
- **#2b is profile-gated.** The plan's own Step 1 demands CloudWatch metrics first. Without evidence of an actually hot fence in production, this is large speculative work. The +N× WCU cost only buys you anything if you're hitting the ~500 transactions/sec/fence ceiling.
- **#3 can run any time.** Half a day, zero runtime impact, zero risk. Slot it in opportunistically — e.g. while someone is already in `Runtime.res` for #2a.
- **#4 narrowed by the 2026-05-10 fix.** With `appendUnconditional` migrated to `TransactWriteItems`, the DCB log no longer uses `BatchWriteItem` at all. `BatchWriteItem` chunking (#4) is now scoped to `QueryDb`'s read-model batch persistence only — narrower blast radius justifies the lower position.
- **#6 last but with a real ROI argument.** Unlike most "optimization" backlog items, this one *reduces* DynamoDB spend rather than just trading complexity for speed. For a high-volume slice with warm-Lambda reuse, even a 30% cache hit rate translates to measurable RCU savings. Worth scheduling against actual production cost data — if read RCU is a non-trivial line item, it can jump priority.

### Cost-driven order: rank by net 6-month value

If you optimise for *value over a 6-month horizon* (correctness first, then runtime savings net of dev cost):

1. **#1** — non-negotiable correctness gap.
2. **#4** — half-day freebie. Land it whenever someone touches the file.
3. **#3a** — small dev cost, immediate per-write savings, no profiling prerequisite. Pays back fastest.
4. **#2** — verification debt. Has to land before #3b can be trusted.
5. **#6** — only if production read RCU bills justify the dev cost; otherwise demote.
6. **#5** — narrowed scope after #1, but still a sharp edge worth filing off.
7. **#3b** — only if profiling shows a real hot fence. Otherwise indefinite defer.

The "by priority" table above lists the canonical execution order driven by class (correctness → verification → ceiling → cleanup → optimization). The "by 6-month value" list above re-shuffles for cost-aware planning — useful if engineering capacity is tight and you want to maximise observable wins per sprint.

### What can run in parallel

- #4 (monotonic positions) — **DONE 2026-07-08** (was independent of everything else).
- #3a (selective bumping) is independent of the storage adapter shape — only PPX + the `extraEventTags` filter. Can be developed concurrently with anything below the API line.
- #6 (projection cache) is independent of the storage adapter — can be developed concurrently with anything below the API line.
- #1 and #2 should be sequential (close the hole, then verify the whole atomic-append story).
- #3b should follow #2 (use the harness) and ideally also #3a (so sharding ships on top of an already cost-trimmed fence set).
