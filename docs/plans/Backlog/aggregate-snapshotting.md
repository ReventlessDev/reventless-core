# Plan: Aggregate Snapshotting for Long Event Logs

**Analysis**: [aggregate-command-handling-review.md](../../analysis/aggregate-command-handling-review.md) — Performance §"Long-tail aggregates" and Cost §"Snapshotting → replay → ~constant RCU"

## Problem

Every Aggregate command pays for a full strongly-consistent replay of the entity's event log. Cost and latency scale linearly with event count. For long-lived aggregates (running orders, ledgers, persistent counters, multi-month workflows), this becomes the dominant cost and the throughput ceiling.

The fence-based DCB approach sidesteps this for slice-shaped consistency boundaries, but plenty of legitimate use cases are aggregate-shaped and just need their replay cost capped.

This plan is **profile-gated and deferred**: it should only ship when production data shows the linear replay cost is a real bill, not a theoretical concern. Until then, [aggregate-replay-cost-documentation.md](aggregate-replay-cost-documentation.md) is the right level of investment.

## Goals

- Replay cost becomes O(events_since_last_snapshot) + 1 snapshot read, instead of O(events).
- Snapshot freshness is configurable per aggregate. Default: every N events (e.g. 100), tunable in spec.
- Snapshots never affect correctness — they are a read optimization. The fence (sequence number for Aggregate; tag fence for DCB) remains the only consistency primitive.
- Snapshot misses degrade gracefully — fall back to full replay.
- Snapshot writes happen async, off the critical path, so a snapshot failure never blocks a command.

## Non-goals

- Snapshotting for DCB. DCB has different consistency mechanics; the slice-level decision-model cache plan ([dcb-decision-model-projection-cache.md](dcb-decision-model-projection-cache.md)) is the analogue.
- Snapshot deserialization for analytics or external systems. Snapshots are an internal replay optimization, not a new external surface.
- Custom serialization formats. Use the same `Spec.stateSchema` (or equivalent) — events already ride sury, and state can too.

## Approach

A snapshot is a record `{id, snapAtSeq, state}` written to a sibling DynamoDB table (or a side key in the same table — see decision below).

### Snapshot store options

| Option | Pros | Cons |
|---|---|---|
| **Separate DDB table** | Clean separation; independent scaling; easy to rebuild | Extra resource; cross-table reads cost an extra round-trip per command |
| **Same table, side key** (`id`, `seq = "SNAPSHOT"`) | One read combines snapshot + delta-replay | Read filter becomes more nuanced; admin queries for "all events" need to exclude snapshot rows |

**Recommendation**: same-table side key. The replay query already scans by `id` partition key; pulling the snapshot row in the same query is one round-trip. Filter snapshot rows out of event-folding logic in user space.

### Replay flow with snapshots

```rescript
let replayWithSnapshot = id => {
  // One DynamoDB query for the whole partition, ordered by seq
  let items = await ddb.query({
    KeyConditionExpression: "id = :id",
    ConsistentRead: true,
  })

  let (snapshot, events) = items->Array.partition(isSnapshot)

  let (initialState, startingSeq) = switch snapshot {
  | Some(s) => (s.state, s.snapAtSeq + 1)
  | None => (Behavior.initialState, 0)
  }

  // Delta-replay: events with seq >= startingSeq
  let finalState = events
    ->Array.filter(e => e.seq >= startingSeq)
    ->Array.reduce(initialState, Behavior.evolve)

  (finalState, events.length)  // sequenceNr for OCC = total events
}
```

### Snapshot write trigger

After every Nth successful append (configurable; default 100), write a fresh snapshot. The write is **fire-and-forget** — it cannot block the command path. Implement as an `Effect.fork` after `reportAccepted`.

```rescript
if (newSeq mod snapshotInterval == 0) {
  Effect.fork(writeSnapshot(id, newSeq, state))
}
```

A snapshot write failure just means the next command does a longer delta-replay. Self-healing.

### Sequence numbering with snapshots

The snapshot row uses a special `seq` value (e.g. `"SNAPSHOT"` or `"_snapshot"`) that sorts outside the event range. The OCC `attribute_not_exists(seq)` check is unaffected — events still take consecutive integer `seq`s.

### Old snapshot cleanup

Two strategies:

- **Keep one**: overwrite the same `(id, "SNAPSHOT")` row on each snapshot write. One row per aggregate, always current.
- **Keep last K**: write to `(id, "SNAPSHOT#${seq}")` and prune older ones in a background sweep. More resilient to a corrupt snapshot, more storage.

**Recommendation**: keep-one. Aggregates with corrupt snapshots are rare; if it happens, falling back to full replay (from event 0) is the recovery path.

## Steps

### Step 1 — Profile production

Before any code change, gather:

- Distribution of aggregate event counts (p50, p95, p99) from a representative table.
- Lambda invocation duration histograms — does replay-and-decide saturate the 180s SQS visibility window?
- DynamoDB RCU spend per Aggregate plugin per month.

If p95 event count is < 50 and RCU spend is < 5% of total bill, snapshotting is premature optimization. Defer indefinitely.

If p95 > 500, or RCU > 20% of bill, or any aggregate routinely runs > 30s on replay, proceed.

### Step 2 — Schema decision

Confirm same-table side-key is acceptable for the production tables. Run a one-off query to verify no operational tooling assumes "all rows in EventLog are events" (e.g. ETL pipelines, admin dashboards). If something does, add a filter or revisit the separate-table option.

### Step 3 — Spec extension

Add to `Spec.Aggregate`:

```rescript
let snapshotInterval: option<int>  // None = no snapshots; Some(n) = every n events
let stateSchema: S.t<state>  // for snapshot serialization
```

Existing aggregates without `snapshotInterval` continue to use full replay — backwards compatible.

### Step 4 — Adapter changes

In [`EventLogStorage_DynamoDb_Runtime.res`](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res):

- New `replayWithSnapshot(id)` returning `(events, snapshot?)` from one query.
- New `writeSnapshot(id, seq, stateJson)` — single conditional `PutItem` on `(id, "SNAPSHOT")` (no `attribute_not_exists` since we overwrite).
- New `appendStream` / `replayStream` variants if the snapshot needs to be pulled into streaming flows (probably yes).

### Step 5 — Aggregate callback wiring

In [`Aggregate_Callback.res`](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res):

- Replace `Ops.eventLog.replayStream(id)` → `(initialState, startingSeq)` fold with `Ops.eventLog.replayWithSnapshot(id)` — returning `(initialState, sequenceNr)` where `sequenceNr` is the total event count, used for the OCC condition.
- After successful append, fork a snapshot write if `(newSeq mod snapshotInterval == 0)`.

State serialization: encode via `Spec.stateSchema` (sury) and store as JSON in DynamoDB.

### Step 6 — Tests

Unit tests in `reventless/reventless-aws/tests/EventLogStorage_DynamoDb_RuntimeTest.res`:

- Replay with no snapshot → behaves exactly as today.
- Replay with snapshot at seq=50 + 5 new events → state = snapshot.state evolved through 5 events, sequenceNr = 55.
- Replay with corrupt/decode-error snapshot → falls back to full replay (log a warning).

Integration tests in `tests/components/Aggregate`:

- Aggregate with `snapshotInterval = Some(10)` writes a snapshot at seq=10, 20, 30.
- 25-command burst against an aggregate with snapshotInterval=10 produces correct final state.
- Snapshot write failure does not fail the command (fire-and-forget verified).

End-to-end in `examples/online-shop-aggregates/`:

- Configure an aggregate with `snapshotInterval = Some(50)`, run the existing GWT corpus, verify behaviour identical.

### Step 7 — Migration / rollout

For existing tables:

- Adding `snapshotInterval` to a spec is non-breaking — new tables and existing tables both work.
- The first snapshot write per aggregate happens at the next command after the threshold.
- No backfill needed; replay cost decays naturally as snapshots accrete.

### Step 8 — Documentation

Update [`docs/reventless-components/aggregate.md`](../../reventless-components/aggregate.md) "Cost and capacity model" (added by [aggregate-replay-cost-documentation.md](aggregate-replay-cost-documentation.md)) to describe snapshot configuration and the cost shift.

Move plan to `done/`. Update analysis to mark resolved.

## Open questions

- **Snapshot interval default**: 100? 50? Workload-dependent. Start with `None` (snapshots opt-in), users tune from there. After production data, consider a sensible default.
- **What if `Behavior.evolve` changes between deploys?** A snapshot was computed by the old `evolve`; the new `evolve` might disagree. **Mitigation**: include a `behaviorVersion` in the snapshot; on version mismatch, ignore the snapshot and fall back to full replay. Simpler: store the behavior module URL hash. Defer until it bites.
- **Concurrent snapshot writes?** Two Lambdas could both decide to snapshot at seq=100 (different command batches landing simultaneously). Both write to `(id, "SNAPSHOT")`; last-writer wins. Both writes contain the same state at seq=100, so either outcome is correct. No locking needed.
- **Should snapshots be encrypted differently from events?** Same key, same encryption-at-rest — they're the same table.

## Status

Not started. Profile-gated. **Do not start work until production data justifies it.**
