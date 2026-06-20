# Plan: Close the `appendUnconditional` Fence-Bypass Footgun

**Analysis**: [dcb-dynamodb-consistency-check.md](../../analysis/dcb-dynamodb-consistency-check.md) — current state §"Caveats and footguns", item 1
**Sibling plan**: [dcb-dynamodb-atomic-append.md](../done/dcb-dynamodb-atomic-append.md)

## Problem

`DcbEventLogStorage_DynamoDb_Runtime.appendUnconditional` ([Runtime.res:607-617](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L607-L617)) writes events via `BatchWriteItem` without touching the per-tag fence sentinels that the conditional path maintains. The public `append` adapter API routes to it whenever the caller passes `condition=None`:

```rescript
let append = (table, ~partitionTag=?) =>
  async (events, ~condition=?) =>
    switch condition {
    | None => await appendUnconditional(table, events, ~partitionTag?)
    | Some(cond) => await appendConditional(table, events, cond, ~partitionTag?)
    }
```

`StateChangeSlice_Callback.handleSingleCommand` always passes a condition, so this isn't reachable from the slice. But the path is exposed to any other adapter consumer (translation slices that import from external sources, seeding scripts, replay tooling, anything bypassing the slice DSL).

### Why it's a real correctness bug

A concurrent conditional writer reads tags T1, sees no events (`after = None`), builds condition `attribute_not_exists(lastPosition)`. Meanwhile an unconditional writer writes events tagged T1 — events land in the base table + GSIs, but the T1 fence is *not* bumped. The conditional writer's `TransactWriteItems` commits because `attribute_not_exists` still holds. Now the conditional writer's decision model was wrong (it didn't see the unconditional writer's events) and it committed anyway. The DCB invariant for T1 is silently violated.

The atomicity guarantee only holds if **every** writer touching a tag bumps that tag's fence. The current code lets one path opt out.

## Goals

- Eliminate the silent path that lets writes land without bumping fences they should bump.
- Preserve a way to write events without a *consistency check* (legit use case: imports, seeding, replay), but only as long as the fence is still maintained.
- No API change visible to `StateChangeSlice` (the conditional path stays the conditional path).

## Non-goals

- Rewriting the inbound translation pipeline to use conditional appends. Translation slices intentionally don't run optimistic concurrency — they trust their upstream source. They just need their writes to be visible to downstream conditional writers via the fence.
- Removing the public `append` API. Other adapters (in-memory, sqlite) implement it the same way; the contract is shared.

## Approach

Three options, ordered by preference.

### Option A — Make `appendUnconditional` bump fences unconditionally (preferred)

Repurpose the path: it stops being "no fence" and starts being "no condition, but fence still bumped". `appendConditional` already has the unconditional-bump code for `extraEventTags` ([L657-660](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L657-L660)) — extract and reuse it.

```rescript
let appendUnconditional = async (table, events, ~partitionTag=?) => {
  let basePosition = generatePosition()
  let eventTags = collectEventTags(events)
  let totalItems = events->Array.length + eventTags->Array.length
  if totalItems > transactWriteItemsLimit {
    Error(`Unconditional append: TransactWriteItems limit exceeded …`)
  } else {
    let putItems = events->Array.mapWithIndex((event, idx) => {
      let position = generatePositionForBatch(basePosition, idx)
      let item = toItem(position, event, ~partitionTag?)
      {TransactWriteCommand.put: {item, tableName: table.name}}
    })
    let updateItems =
      eventTags->Array.map(tag =>
        {TransactWriteCommand.update: buildUnconditionalFenceUpdate(table.name, tag, ~newPosition=basePosition)}
      )
    let input = {transactItems: Array.concat(putItems, updateItems)}
    // … same Effect.tryPromise / TransactWriteCommand.send / error mapping as appendConditional
  }
}
```

**Pros:** Closes the bypass without removing the API. `BatchWriteItem` goes away from this path — `TransactWriteItems` is the only write primitive in the DCB log.
**Cons:** Higher per-write cost (2× WCU per item vs 1× for `BatchWriteItem`). Translation slices that produced thousands of events per import now pay 2× for fence maintenance. Acceptable price for correctness.
**100-item cap:** Same as conditional path. A single import producing 51+ events with one tag each hits the cap. Mitigated by chunking at the call site.

### Option B — Remove `appendUnconditional` entirely

Make `~condition` non-optional on the public `append` API. Force every caller to declare their consistency intent — even "no concurrency check, but please bump these fences" becomes a real condition like `{query: <event tags>, after: None}` (which translates to fence-bump-only).

**Pros:** No silent path possible. Type system enforces correctness.
**Cons:** Cross-adapter API change (in-memory, sqlite must follow). Migration cost across translation slices and any tooling. Worse ergonomics for clearly-non-DCB use cases (e.g. test fixtures).

### Option C — Document `appendUnconditional` as DCB-unsafe and emit a runtime warning

Keep the path; rename to `appendUnsafeUnconditional` or similar; log a warning on every call. No semantic change.

**Pros:** Cheapest fix.
**Cons:** Doesn't fix anything. The warning gets ignored in production; the bypass remains. Solves a documentation problem, not a correctness problem.

## Steps

### Step 1 — Pick the option

Default to A. Confirm by checking current `appendUnconditional` callers across the workspace (`grep -rn "appendUnconditional"` — only the internal `append` switch routes to it today; no external direct callers found in the last review). If no caller depends on the old `BatchWriteItem` semantics or the > 100-item capacity, A is unambiguous.

### Step 2 — Implement (Option A)

In [`DcbEventLogStorage_DynamoDb_Runtime.res`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res):

- Refactor `appendConditional` to extract a private `buildEventPuts` helper (event Puts with batch positions). Reuse from both paths.
- Rewrite `appendUnconditional` per the sketch above. Drop the call to `writeEventsWithPosition` (`BatchWriteItem` path).
- Surface the same 100-item rejection as the conditional path.
- Same error classification (`StaleState` shouldn't appear on this path because there are no conditions, but `Transient` from `TransactionConflict` against fence partitions can — handle it).

### Step 3 — Tests

In [`DcbEventLogStorage_DynamoDb_RuntimeTest.res`](../../reventless/reventless-aws/tests/DcbEventLogStorage_DynamoDb_RuntimeTest.res):

- `appendUnconditional` with 0 events + 0 tags → succeeds with `Ok(position)` and emits an empty transaction (or skips the call — match conditional path's edge case).
- `appendUnconditional` with N events + M unique event tags → produces a `TransactWriteItems` with `N + M` items.
- `> 100` items rejected up front with a clear error.
- (Integration test, deferred to [`dcb-dynamodb-atomic-append-integration-test.md`](dcb-dynamodb-atomic-append-integration-test.md)) After an unconditional append, a subsequent conditional append on the same tags correctly observes the bumped fence and is forced to use `lastPosition <= :after` (not `attribute_not_exists`).

### Step 4 — Audit and migrate any direct callers

Run `grep -rn "appendUnconditional\|append.*condition=None\|~condition=None"` across `reventless/` and `examples/`. Update any caller that depended on the old semantics.

### Step 5 — Document

Update [`docs/analysis/dcb-dynamodb-consistency-check.md`](../../analysis/dcb-dynamodb-consistency-check.md) §"Caveats and footguns" item 1: mark resolved. Move this plan to `done/`.

## Open questions

- **Multi-table fence semantics for non-`StateChangeSlice` consumers.** If translation slices write events into a different table than the conditional writers read from, fence bumps don't help. Confirm during Step 4 audit that all DCB-relevant writes target the same table per plugin.
- **Backwards compat with seed/import scripts** that produce > 100 events per call. They'd need to chunk at the call site under Option A. Document the migration in the plan's `done/` writeup.
- **Should the renamed unconditional path stay public, or move to an `__unsafe__` namespace?** Option A keeps it public; Option B-light could rename to flag the cost change without breaking the API shape.

## Status

**Done (2026-05-10).** Took **Option A**.

Audit confirmed no direct callers of `appendUnconditional` outside the internal `append` switch — `grep -rn "appendUnconditional\|condition=None\|~condition=None"` across the workspace returned only the runtime-internal callsite. Translation slices flow through commands rather than the adapter `append`, so the migration was safe with no caller updates.

### What landed

- Extracted `buildEventPuts` helper. Both append paths now share the same event-Put construction.
- Extracted `runTransactWrite` helper. Single `TransactWriteItems` call site with shared error classification (`StaleState → Conflict:`, `Transient/Permanent → DCB append failed:`).
- Rewrote `appendUnconditional`: per-event Puts plus one `buildUnconditionalFenceUpdate` per event tag, single `TransactWriteItems`.
  - 100-item rejection up front.
  - Empty-events early-return preserves the public contract that callers may pass `[]`.
- Deleted `writeEventsWithPosition` (the only `BatchWriteItem` consumer in the DCB log path).
- Two new unit tests in `DcbEventLogStorage_DynamoDb_RuntimeTest.res`:
  - `Runtime.buildEventPuts` — emits one Put per event with the table name; returns no Puts for empty events.
  - `Runtime.appendUnconditional` — rejects > 100 items with a clear `limit exceeded` error before any AWS call.
  - All 26 tests pass; root build clean (zero warnings).

### Trade-offs accepted

- Per-write cost rose from `1× WCU/item` (`BatchWriteItem`) to `2× WCU/item` (`TransactWriteItems`). For a single-event/single-tag append, that's 1 → 4 WCU. Translation/seed/replay paths now pay this for the correctness benefit.
- 100-item per-call cap (the `TransactWriteItems` limit) replaces the 25-item cap of `BatchWriteItem`. Net more headroom per call, though both still require chunking at the call site for large imports.

### Open follow-ups

- **Integration test against real DynamoDB** — deferred to [`dcb-dynamodb-atomic-append-integration-test.md`](dcb-dynamodb-atomic-append-integration-test.md). Should add a scenario: after an unconditional append, a subsequent conditional append on the same tags is forced to use `lastPosition <= :after` instead of `attribute_not_exists`.
- **Multi-table fence semantics** — not actionable here; only relevant if a translation slice is configured to write events into a different table than the conditional writers read from. No such configuration exists in the repo today.
- **Backwards compat with seed/import scripts** producing > 100 events per call — must chunk at the call site. None exist in the workspace today; document the requirement when one appears.
