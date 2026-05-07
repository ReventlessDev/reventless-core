# Plan: Strongly-Consistent Reads on the Single-Tag DCB Decision-Model Path

**Analysis**: [dcb-dynamodb-consistency-check.md](../../analysis/dcb-dynamodb-consistency-check.md) — Consistency issue #3
**Sibling plan**: [dcb-dynamodb-atomic-append.md](../done/dcb-dynamodb-atomic-append.md)

## Problem

`StateChangeSlice_Callback` does a decision-model read via `dcbEventLog.readStream(~query)` before calling `Behavior.decide`. The slice's read goes through the same routing as any other DCB query:

- Single-tag query → `queryByPartitionKeyStream` (base table)
- Multi-tag query → `queryByCompositeTagsStream` (GSI `tag_composite`)
- Tagless query → `scanWithFilterStream`

Today `queryByPartitionKeyStream` does not pass `consistentRead: true`. The base table supports strong consistency for free (the table's own writes are immediately visible). DynamoDB defaults `Query` to eventually consistent. So even on the single-tag fast path — where strong consistency is technically possible — the slice may read stale events.

This is **not a correctness issue under the new atomic-append design**: missed events trigger fence-condition failures at commit time → slice retries → eventually consistent. But it costs an unnecessary retry round trip whenever the GSI happens to be lagging.

GSI-based reads (multi-tag, composite) cannot opt into strong consistency — fundamental DynamoDB constraint. So this plan only applies to the single-tag base-table path.

## Goals

- `queryByPartitionKeyStream` supports strong consistency.
- The slice opts in for its decision-model read on single-tag queries.
- Unconditional (non-DCB) callers remain on eventually-consistent reads (cheaper, and they don't need the guarantee).
- No change to read semantics for multi-tag or tagless queries.

## Non-goals

- Strong consistency for `read` (the eager non-streaming variant). Slice uses `readStream`.
- Forcing strong reads everywhere. ECC reads are half the cost; only use SC where it pays.

## Approach

Add an optional `~strongConsistency: bool=?` parameter to `queryByPartitionKeyStream` (and the parallel non-stream `queryByPartitionKey`). Thread through to `consistentRead` on the `QueryCommand.input`. Default off — preserves current behaviour for callers that don't opt in.

Then add a similar opt-in path through `executeQueryItemStream` and `readStream` so the slice can enable it. Important: only the single-tag branch consumes the flag — multi-tag and scan branches ignore it (and would error if they tried, since DynamoDB rejects `consistentRead: true` on GSIs).

### Wiring

```rescript
// DcbEventLogStorage_DynamoDb_Runtime.res

let queryByPartitionKeyStream = (
  table,
  partitionKey,
  ~after=?,
  ~strongConsistency=false,
) => {
  let baseParams: QueryCommand.input = {
    tableName: table.name,
    consistentRead: ?strongConsistency ? Some(true) : None,
    keyConditionExpression: ...,
    ...
  }
  ...
}

let executeQueryItemStream = (table, queryItem, ~after=?, ~strongConsistency=false) =>
  switch queryItem.tags {
  | Some([tag]) =>
    queryByPartitionKeyStream(
      table,
      `${tag.key}:${tag.value}`,
      ~after?,
      ~strongConsistency,
    )
  | Some(tags) if tags->Array.length > 1 =>
    // Strong consistency not available on GSIs — silently ignore the flag.
    queryByCompositeTagsStream(table, tags, ~after?)
  | None | Some([]) | Some(_) => ...
  }
```

Then `readStream` accepts the flag and threads it through.

### Slice integration

The slice should opt in only when its query collapses to single-tag form. `Reventless.DcbTag.buildQueryFromCommand` returns either:

- One queryItem with one or more tags (scalar-tagged commands)
- Multiple queryItems with one tag each (array-tagged commands)

Both can use single-tag base-table reads on each queryItem. So opt in unconditionally; the runtime will ignore the flag for any queryItem that falls back to GSI / scan.

Alternative: don't propagate from the slice; flip the default to `true` in `executeQueryItemStream` since it's safe to ignore where unsupported. That's simpler — no API change to the public `readStream`. Decide during Step 1.

## Steps

### Step 1 — Decide opt-in vs default-on

Default-on inside `executeQueryItemStream` keeps the public API stable and ensures all DCB slice reads benefit. Cheaper code change. Recommend default-on unless someone surfaces a regression.

### Step 2 — Implement

Add `consistentRead` to `queryByPartitionKeyStream` (and non-stream variant). Wire via the chosen approach.

### Step 3 — Tests

Unit-level: confirm the `QueryCommand.input` carries `consistentRead: true` for the single-tag path and not for the multi-tag / scan paths. Pattern follows the existing `DcbEventLogStorage_DynamoDb_RuntimeTest.res`.

### Step 4 — Verify behaviour in the AWS integration test

Once the AWS integration test plan ([dcb-dynamodb-atomic-append-integration-test.md](./dcb-dynamodb-atomic-append-integration-test.md)) lands, add a regression: write event A → immediately read with `strongConsistency=true` → A must be visible. Compare to `strongConsistency=false` where DynamoDB Local may serve stale.

### Step 5 — Document

Update analysis doc consistency issue #3 to mark resolved on the single-tag path; note the GSI-path limit is fundamental and cannot be fixed.

## Cost implications

Strongly-consistent reads cost 1 RCU per 4KB read; eventually-consistent reads cost 0.5 RCU per 4KB. So slice decision-model reads on single-tag queries become 2× the read cost. Trade-off: ~50% of conflict retries (which themselves are read+write+retry cycles) avoided when GSI is lagging. Net usually positive under contention; potentially negative under low contention with large state. Worth measuring after rollout.

## Status

Not started.
