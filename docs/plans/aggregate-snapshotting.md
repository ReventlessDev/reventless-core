# Plan: Aggregate Snapshotting for Long Event Logs

**Analysis**: [aggregate-command-handling-review.md](../analysis/aggregate-command-handling-review.md) — Performance §"Long-tail aggregates" and Cost §"Snapshotting → replay → ~constant RCU"

**Progress log:**
- 2026-07-03 — **Step 1 done — Phase 1 in-process replay cache** (core). `Aggregate_Callback` gained a per-functor-instance `Lru.t<string, (Behavior.state, int)>` (capacity 100, matching the slice cache) keyed by the aggregate id — the functor instance owns the cache, so the event log is implicit and the plan's `logName + id` key reduces to `id`. Warm path: `replayProcessAppend` skips `replayStream` entirely and decides on the cached `(state, sequenceNr)`; after a successful append it stores the **already-folded post-decide state** at `sequenceNr + appended` (the processCommand fold's `finalState`, previously discarded as `_finalState` — aggregates have no consumed-vs-produced event split, so evolve-over-appended IS the replay result, exactly as the plan's design argued); the `Ok([])` no-events branch re-puts the read snapshot (keeps it warm + refreshes recency); `Error(Conflict)` **and** `Error(StorageFailure)` invalidate the entry so the retry/next attempt replays cold. The plan's "fail-closed unserializable key" test is moot for aggregates — the key is `Spec.Id.toString(id)`, always a plain string. `resetCache: unit => unit` exported on `Aggregate_Callback.T` for test isolation (production never needs it) and wired into all four existing aggregate test files' `beforeEach` (their module-level `TestHandler` would otherwise leak warm state across tests — the conflict suite pins exact `replayCallCount`s). New `AggregateCacheTest` (**5 tests**) with the package's first **OCC-enforcing** mock EventLog (the existing mocks ignore `seqNr`, but the cache's correctness argument rests on that fence): warm same-id command skips replay; cached fold ≡ cold replay (a `Checkpoint` command records the decision state's size as an event — warm and post-`resetCache` cold checkpoints both observe 3); **stale-cache self-heal** (an injected second-writer event → warm append conflicts → invalidate → cold retry succeeds and the refreshed state includes the external event); `Ok([])` keeps the snapshot warm; `resetCache` forces a cold replay. **Verified**: core **45 suites / 485 tests** (+5), local **464**, aws **133**, all green, zero warnings; catalog example through the real gwt runner **44/0**; and a **live platform smoke** (online-shop-aggregates `platform-local`, SQLite): AddProduct → UpdatePrice → UpdateName on one id logged `replay: … 0 event(s)` then `replay skipped (cached): seq=1` then `seq=2` — on both the Catalog `Product` aggregate **and** the extension-synced Ordering `CatalogProduct` — with the read model correctly showing the final name/price. **Next**: Step 2 (config surface) — blocked on a reventless-ppx republish.

**Scope note (2026-07-03)**: absorbed the aggregate-snapshot items from
[quality-performance-hardening.md](quality-performance-hardening.md) B5 — the in-process
LRU delta-seed port (Phase 1) and the persisted `snapshot(log_name, aggregate_id, seq_nr,
state)` table for long local sessions (Phase 2, SQLite arm). This plan is now the single
home for aggregate replay-cost optimization; B5's remaining scope is persisted-data
versioning only. Scope widened from the original DynamoDB-only draft: snapshots must be
supported by **all aggregate EventLog backends** (local InMemory, local SQLite, AWS
DynamoDB), and the feature is **configurable per aggregate** — off by default.

## Problem

Every Aggregate command pays for a full replay of the entity's event log from seq 0
([Aggregate_Callback.res:136-137](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res)),
and again per optimistic-concurrency conflict retry (up to 3×). Cost and latency scale
linearly with event count. For long-lived aggregates (running orders, ledgers, persistent
counters, multi-month workflows), this becomes the dominant cost and the throughput
ceiling — on AWS as RCU spend and Lambda duration, and on the local platform as
replay-heavy dev sessions under SQLite (the B5 motivation).

The fence-based DCB approach sidesteps this for slice-shaped consistency boundaries — and
StateChangeSlice already ships the in-process decision-model LRU cache
([StateChangeSlice_Callback.res:110-137](../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res))
— but plenty of legitimate use cases are aggregate-shaped and just need their replay cost
capped.

## Goals

- **Phase 1 (in-process, always-on, zero config)**: warm same-entity commands skip the
  full replay via an LRU `(state, seqNr)` cache — the aggregate analogue of the slice
  decision-model cache. Backend-independent (lives in `Aggregate_Callback`).
- **Phase 2 (persisted, opt-in, configurable)**: replay cost becomes
  O(events_since_last_snapshot) + 1 snapshot read, instead of O(events) — including on a
  cold start. Supported uniformly by **all three** EventLog backends.
- Snapshots never affect correctness — they are a read optimization. The OCC sequence
  number remains the only consistency primitive: a stale cache/snapshot can only produce a
  stale *decision*, which the conditional append rejects → retry re-reads.
- Snapshot misses, decode failures, and schema drift degrade gracefully — fall back to
  full replay.
- Snapshot writes happen off the critical path; a snapshot write failure never blocks or
  fails a command.
- Aggregates that don't opt in are byte-for-byte unaffected (beyond the Phase 1 cache).

## Non-goals

- Snapshotting for DCB. The slice-level decision-model cache
  ([dcb-decision-model-projection-cache.md](dcb-decision-model-projection-cache.md)) is
  the analogue and already exists.
- Snapshot deserialization for analytics or external systems. Snapshots are an internal
  replay optimization, not a new external surface.
- Custom serialization formats. State rides sury like events do.

## Configuration

Off by default; opt-in per aggregate. Snapshots serialize `Behavior.state`, so the
configuration lives on the **Behavior** module (where `state` is defined), not the Spec.

New `Reventless.Snapshot` in `reventless-spec`:

```rescript
type config<'state> = {
  /** Write a snapshot after every N appended events. Required — no magic default. */
  interval: int,
  /** Sury schema for the state — from `@schema type state`, which behavior files
      already conventionally carry. Required for persistence. */
  stateSchema: S.t<'state>,
}
```

`Behavior.T` gains:

```rescript
/** `None` (default) = no persisted snapshots; full replay (Phase 1 cache still applies). */
let snapshot: option<Snapshot.config<state>>
```

- **Default injection**: `@@reventless.behavior` auto-injects `let snapshot = None` when
  absent — existing behavior files compile unchanged. Same pattern as `readConsistency`
  on slices; same constraint: **the PPX injection needs a reventless-ppx republish before
  the module-type change can pass CI** (see memory: required-field auto-injections).
- **Ergonomic form**: optional file-level attribute `@@reventless.snapshots(100)` on a
  behavior file injects `let snapshot = Some({interval: 100, stateSchema})` (requires
  `@schema type state`; the PPX errors if the schema is missing). Hand-writing the `let`
  works identically — the attribute is sugar, not the mechanism.
- **Parameters deliberately minimal for v1**: `interval` only. Keep-policy is fixed at
  keep-one (see below); the Phase 1 LRU capacity is fixed at 100 entries (matching the
  slice cache — its comment already marks a per-component knob as a future refinement).
  Add knobs only when a workload demonstrates the need.

## Approach

### Phase 1 — in-process LRU delta-seed (from B5; no persistence, no config)

Port the StateChangeSlice pattern to `Aggregate_Callback`: a per-warm-instance
`Lru.t<string, (Behavior.state, int)>` keyed by `logName + aggregateId`, holding the
`(state, sequenceNr)` the previous command for that id derived.

Key design difference from the slice: aggregates have **no consumed-vs-produced event-type
split** (`evolve` consumes exactly what `decide` produces), so after a successful append
the callback **folds its own produced events into the cached state** and bumps the seq —
no delta *read* is needed on the warm path at all, and therefore **no storage-surface
change**. The cache-warm flow:

1. Cache hit → skip `replayStream` entirely; decide on the cached state; append with the
   cached seqNr as the OCC condition.
2. Append `Ok` → evolve cached state through the produced events, `seqNr += produced`.
3. Append `Error(Conflict)` (another writer advanced the stream — cold Lambda, second
   instance) → **invalidate the cache entry**, full replay, retry as today.
4. Any other error / unserializable key → bypass the cache (fail closed, as the slice's
   `None`-key handling does after the B6 fix).

Correctness rests entirely on the OCC fence, exactly as documented for the slice cache: a
stale cached state only changes the decision; a stale decision conflicts at append time.
Per-id FIFO command grouping (both AWS SQS FIFO and the local topic) makes the warm path
the common case.

### Phase 2 — persisted snapshots (opt-in, all backends)

A snapshot is `{seqNr, state: JSON.t, schemaHash: string}` — the folded state as of
`seqNr`, plus a validity hash.

#### Storage surface (core adapter contract)

Extend `EventLog.operations` (and the storage adapter interface each backend implements):

```rescript
type snapshot = {seqNr: int, state: JSON.t, schemaHash: string}

latestSnapshot: 'id => promise<result<option<snapshot>, string>>,
writeSnapshot: ('id, snapshot) => promise<result<unit, string>>,
// replayStream gains an offset so the delta after a snapshot is readable:
replayStream: ('id, ~afterSeq: int=?) => Stream.t<'event, string, unit>,
```

Keep-one semantics everywhere: `writeSnapshot` overwrites the single snapshot row per
aggregate. Recovery from a corrupt snapshot is full replay, not older snapshots.

#### Per-backend implementation

| Backend | Snapshot storage | Notes |
|---|---|---|
| **local InMemory** | dict keyed `(logName, id)` | Perf-irrelevant but mandatory for backend parity — GWT/local tests of snapshot-enabled aggregates must behave identically under both local backends. |
| **local SQLite** | new `snapshot(log_name, aggregate_id, seq_nr, state, schema_hash)` table, PK `(log_name, aggregate_id)` (the B5 shape) | `INSERT OR REPLACE`. Coordinates with B5's persisted-data-versioning decision (`PRAGMA user_version`) for the table's own migration story. |
| **AWS DynamoDB** | same-table side key `(id, seq = "SNAPSHOT")` | One partition query serves snapshot + delta in a single round-trip; plain `PutItem` (overwrite, no `attribute_not_exists`). Event OCC (`attribute_not_exists(seq)` on integer seqs) is unaffected — the sentinel sorts outside the event range. Verify no operational tooling assumes "all rows are events" before shipping. |

#### Replay flow

```rescript
// Cold path (Phase 1 cache miss), snapshot-enabled aggregate:
let snap = await eventLog.latestSnapshot(id)
let (seedState, seedSeq) = switch snap {
| Ok(Some(s)) if s.schemaHash == currentSchemaHash =>
  switch S.parseJsonOrThrow-style decode of s.state {
  | Ok(state) => (state, s.seqNr)
  | Error(_) => (Behavior.initialState, 0) // corrupt → full replay, warn
  }
| _ => (Behavior.initialState, 0) // absent / drifted / storage error → full replay
}
eventLog.replayStream(id, ~afterSeq=seedSeq)
->Stream.runFold((seedState, seedSeq), ...) // sequenceNr for OCC = total event count
```

#### Snapshot write trigger

After every append that crosses an `interval` boundary
(`newSeq / interval > oldSeq / interval`), serialize the post-append state (Phase 1
already holds it) and fire-and-forget `writeSnapshot`. A failed write just means the next
cold replay reads a longer delta — self-healing. Concurrent writers racing the same
boundary both write the same state at the same seq; last-writer-wins is correct.

#### Staleness / schema drift

`schemaHash` = SHA256 of `SchemaWalker.describeSchema(stateSchema)` (trustworthy since the
A7 fix made it recurse into nested records). On mismatch the snapshot is ignored and
overwritten at the next boundary. This matters **more on the local platform than on AWS**:
under SQLite a dev edits `evolve`/`state` constantly and the stale-snapshot-after-code-change
problem bites immediately, so hash-gating is a v1 requirement, not a hardening follow-up.
Note the hash only detects *shape* changes — a semantics-only `evolve` change with an
unchanged state type is invisible (see Open questions).

## Steps

1. **Phase 1 — LRU delta-seed in `Aggregate_Callback`** (core; no config, no storage
   change). Cache keyed `logName + id`; warm path skips replay; fold-own-events on
   success; invalidate on `Conflict`; `resetCache` for test isolation (as the slice
   exposes). Tests: warm-hit skips replay (mock storage call count), conflict invalidates
   + retry succeeds with fresh read, produced-events fold matches a full replay
   (property-style: cached path ≡ replay path over random command sequences), fail-closed
   key handling.
2. **Config surface** (spec + ppx): `Reventless.Snapshot.config`, `Behavior.T.snapshot`,
   `@@reventless.behavior` default injection, `@@reventless.snapshots(N)` sugar.
   Sequencing: PPX republish **before** the module-type change lands (CI constraint).
3. **Adapter contract** (core): `snapshot` type, `latestSnapshot`/`writeSnapshot`,
   `replayStream(~afterSeq=?)`. Default/legacy behavior: `afterSeq` omitted = from 0.
4. **Backends** (one commit each, with backend tests):
   a. local InMemory — dict; parity tests.
   b. local SQLite — `snapshot` table; reopen-persistence test; align with the
      persisted-data-versioning decision from B5.
   c. AWS DynamoDB — side-key row; single-query snapshot+delta read; runtime tests
      (replay with/without snapshot, corrupt snapshot falls back, `attribute_not_exists`
      OCC untouched).
5. **Callback wiring** (core): cold path consults `latestSnapshot` when
   `Behavior.snapshot` is `Some`; boundary-crossing fire-and-forget write; hash gate.
   Integration tests: `interval = Some(10)`, 25-command burst → snapshots at 10, 20,
   correct final state; snapshot write failure doesn't fail the command; drifted hash →
   full replay; disabled aggregate → zero snapshot reads/writes.
6. **End-to-end**: enable `@@reventless.snapshots(50)` on one `examples/online-shop-aggregates`
   behavior, run the existing GWT corpus + a local-platform SQLite restart smoke
   (kill → restart → command on a snapshotted aggregate replays only the delta) —
   behavior identical, log line shows `replay: … (snapshot@N, K delta event(s))`.
7. **Docs**: extend [aggregate.md](../../packages/doc/docs-app/components/aggregate.md)'s cost model
   (from [aggregate-replay-cost-documentation.md](Backlog/aggregate-replay-cost-documentation.md))
   with the snapshot configuration and cost shift; note the local-backend behavior.
   Move plan to `done/`; mark the analysis resolved.

## Rollout

- Adding `snapshot` to `Behavior.T` with PPX default injection is non-breaking (after the
  republish); existing aggregates keep full replay + Phase 1 cache.
- No backfill: the first snapshot per aggregate is written at the first boundary-crossing
  command after enablement; replay cost decays as snapshots accrete.
- **When to enable (guidance, replaces the old hard profile gate)**: the feature ships
  opt-in, so shipping it is low-risk; *enabling* it on AWS is justified when p95 event
  count > ~500, aggregate-plugin RCU is a visible bill line, or replay approaches the SQS
  visibility window. On the local platform, enable freely for replay-heavy dev sessions —
  that's the B5-derived motivation. Phase 1 needs no gate at all.

## Open questions

- **Semantics-only `evolve` changes**: the schema hash misses an `evolve` edit that keeps
  the state type. Options: fold `Behavior.moduleUrl`'s content hash in (invalidates every
  deploy — safe but wasteful), or accept the risk and document "wipe snapshots on
  behavior-semantics changes" for alpha (consistent with the alpha-wipe-over-migration
  convention). Decide at Step 5.
- **Phase 1 cache capacity knob**: fixed 100 for v1 (slice parity). Revisit alongside the
  slice's own deferred knob if a workload with >100 hot aggregates per instance shows up.
- **Should `latestSnapshot`/`writeSnapshot` be optional in `operations`?** No — all three
  backends implement them in Step 4; an `option` would just move the fallback into every
  caller. A future exotic backend can return `Ok(None)` / no-op.

## Status

In progress — moved out of Backlog 2026-07-03. **Phase 1 (Step 1) is done** (see progress
log). Phase 2 sequencing: config (Step 2) is blocked on a reventless-ppx republish; the
SQLite arm should land with or after B5's persisted-data-versioning decision.
