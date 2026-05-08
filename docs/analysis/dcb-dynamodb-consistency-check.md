# DCB Append Consistency on DynamoDB — Analysis & Options

**Context**: review of the consistency check that runs when a `StateChangeSlice` writes new events through the AWS DynamoDB `DcbEventLogStorage` adapter. Asks: is the check correct? is it performant?

**Verdict**: the check is **not correct under concurrency**, and is **wasteful even in the single-writer case**. The current implementation pretends to enforce optimistic concurrency control but in practice cannot, because the read and the write are independent DynamoDB calls with nothing tying them together.

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

## What the code does today

### Producer side — `StateChangeSlice_Callback.handleSingleCommand`
[`reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res`](../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res)

1. Build a `DcbTag.query` from the command tags.
2. `dcbEventLog.readStream(~query)` — pull every matching event, fold into `(state, headPosition, n)`.
3. `Behavior.decide(state, command)` → `array<Spec.event>`.
4. Encode events; build `appendCondition = { query, after: headPosition }`.
5. `dcbEventLog.append(rawEvents, ~condition)`.
6. On `Error(_)` retry up to `maxRetries = 3` from step 2.

### Storage side — `DcbEventLogStorage_DynamoDb_Runtime.append`
[`reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res:482-514`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L482-L514)

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
([L464-480](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L464-L480)). That is `BatchWriteItem` — no `ConditionExpression` support, no transaction.

---

## Correctness problems

### 1. Read-then-write is not atomic (TOCTOU race) — **critical**

The conflict check and the put are two unrelated DynamoDB requests with nothing serialising them. Two concurrent commands targeting the same consistency boundary can both observe an empty result and both succeed:

```
T1: read  → events = []
T2: read  → events = []        (T1 has not yet written)
T1: write → OK
T2: write → OK                 (DCB invariant violated)
```

The 3-retry loop in `StateChangeSlice` only fires when `append` returns `Error`. With this implementation, the conflicting case usually returns `Ok` from both writers, so retries never trigger and the invariant is silently violated.

This defeats the entire point of the `appendCondition`.

### 2. Tag queries hit GSIs which are always eventually consistent

`queryBySingleTagStream` ([L559](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L559)) and `queryByCompositeTagsStream` ([L601](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L601)) read GSIs.

DynamoDB GSIs **cannot** be read with strong consistency — fundamental product constraint. A just-written event may not appear on the GSI for tens of milliseconds, widening the race window beyond the network RTT.

### 3. Single-tag base-table query does not request strong consistency — **resolved on the single-tag path**

`queryByPartitionKeyStream` hits the base table (`id = pk`). This path *could* set `consistentRead: true` but historically didn't, so even single-tag lookups that could have been strongly consistent went through the eventually-consistent default.

Resolved by [`docs/plans/done/dcb-strong-consistency-single-tag-reads.md`](../plans/done/dcb-strong-consistency-single-tag-reads.md): `queryByPartitionKeyStream` now accepts `~strongConsistency` and `executeQueryItemStream` passes `true` on the single-tag branch. GSI-backed branches (multi-tag composite, tagless scan) cannot opt in — DynamoDB rejects `consistentRead: true` on GSIs — so they remain eventually consistent. The fence-based atomic append (issue #1) ensures correctness either way; strong reads on the single-tag path just save the avoidable conflict-retry round trip when the GSI is lagging.

### 4. `Scan` fallback for tagless queryItems

`scanWithFilterStream` ([L644](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L644)) full-table scans, eventually consistent, no condition guard. As a basis for a consistency decision this is unsound and expensive on any non-trivial table.

### 5. Position ordering breaks ties by UUID

`generatePosition = ${ms}-${uuidv4}` ([L6-10](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L6-L10)). Same-millisecond writers get arbitrary lexical ordering. Combined with the non-atomic write, "events after `headPosition`" is not a well-defined set across concurrent writers.

---

## Performance problems

### 1. Two reads per command, three round-trips minimum

`StateChangeSlice` does its own decision-model read ([Callback.res:78](../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L78)) and then `append` does the **same query again** ([Runtime.res:499](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L499)) before writing. The append-side check is redundant — the slice already paid for that read and knows `headPosition`. If the conflict check were a real precondition on the write request, the second read would not exist.

### 2. The conflict check materialises the full result set just to test emptiness

The append-side `read(...)` paginates all matching events, decodes, dedupes, sorts, then checks `events.length > 0`. For a presence test this should be `Limit: 1` and short-circuit. For hot tag values (e.g. a popular product) this turns a check into a scan.

### 3. `BatchWriteItem` 25-item limit is not chunked

`batchWriteWithRetries` ([Util_DynamoDb_Runtime.res:177](../../reventless/reventless-aws/src/util/Util_DynamoDb_Runtime.res#L177)) only re-drives `unprocessedItems`; it does not split inputs into 25-item batches up front. A command producing ≥26 events fails with `ValidationException` before any retry logic kicks in.

### 4. Retries multiply work

On `Error`, the slice's retry loop re-does the decision-model read. Combined with the duplicate read inside `append`, the cost of a detected conflict is roughly 4× a clean append. The conflicts that actually matter (the ones in §1) bypass this entirely.

---

## Option sketches

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

## Recommendation

Move toward **Option C**. Concrete next steps if/when prioritised:

1. Replace `append` with a `TransactWriteItems` implementation. For single-tag queries, target `(pk, "HEAD")`. For multi-tag, build per-tag fences. Drop the second `read(...)` from the append path entirely.
2. Strip the now-dead "conflict check" code from `append`; rely on `TransactionCanceledException` mapped to `Error("Conflict: …")`. The slice's retry loop already handles this correctly.
3. Stop generating positions in app code. Use a single base position per `TransactWriteItems` call (the head pointer's new value) — atomic with the conditional check.
4. Document or reject tagless DCB queries that include event-type-only fences. They cannot be made consistent on DynamoDB without serialising all writes.
5. Independent of the above: chunk `BatchWriteItem` payloads at 25 items in `batchWriteWithRetries` to remove the `ValidationException` ceiling (this also affects `QueryDb`'s use of the same helper).

The in-memory adapter does not have these problems because its append is synchronous against an in-process structure. Worth comparing semantics side-by-side when implementing the fix to ensure `StateChangeSlice` GWT tests are exercising the conflict path the adapter is meant to enforce.

---

## Implementation status

Implemented (2026-05-08) under [`docs/plans/done/dcb-dynamodb-atomic-append.md`](../plans/done/dcb-dynamodb-atomic-append.md). The implementation landed Option C with simplification: per-individual-tag-value fences only (no separate head-pointer fast path). BatchWriteItem chunking (item 5 above) was deferred as a separate follow-up.
