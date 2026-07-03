# Plan: Aggregate Snapshotting for Long Event Logs

**Analysis**: [aggregate-command-handling-review.md](../analysis/aggregate-command-handling-review.md) — Performance §"Long-tail aggregates" and Cost §"Snapshotting → replay → ~constant RCU"

**Progress log:**
- 2026-07-03 — **Steps 6 + 7 done — example enablement, live smoke, docs. PLAN COMPLETE.** (examples/docs). **(Step 6)**: enabled `@@reventless.snapshots(50)` on `online-shop-aggregates/catalog`'s `Product_Behavior` (the reference example) — the PPX injected `snapshot = {interval: 50, stateSchema}`, catalog GWT corpus stayed **44/0**, `.res.mjs` regenerated with the alpha.49 binary. **Live SQLite restart smoke** (`platform-local`): AddProduct + 55 UpdatePrice on one id → `snapshot written: id=p-snap, seq=50` logged and the SQLite `snapshot` table held the row (`seq_nr=50`); **hard kill → restart → UpdateName** logged exactly the plan's expected marker — `replay: id=p-snap, (snapshot@50, 5 delta event(s))` — i.e. the cold read seeded from the persisted snapshot and folded only the 5-event delta instead of 55, final state correct (`{name:"Renamed", price:55}`), zero ERROR lines. (The delta being 5 not 6 also incidentally proved idempotency: the first `UpdatePrice(1.0)` matched the `Add` price → `Ok([])` no-op.) **(Step 7)**: extended the aggregate component doc's cost model with a "Replay cost and snapshots" section — the always-on in-process cache, the `@@reventless.snapshots(N)` opt-in, keep-one/schema-gated/fire-and-forget/all-backends guarantees, and when-to-enable guidance; no internal plan/step refs. Plan moved to `done/`. **Open questions left as documented decisions** (not blockers): semantics-only `evolve` drift is invisible to the shape hash → wipe snapshots on fold-logic changes (alpha convention); Phase-1 cache capacity fixed at 100 (slice parity). The SQLite snapshot table's migration story still couples to B5's persisted-data-versioning decision when that lands.
- 2026-07-03 — **Step 5 done — callback wiring** (core). `Aggregate_Callback` now consumes `Behavior.snapshot`. **(1) Config + hash + codec** (module-level, computed once): `snapshotConfig = Behavior.snapshot`; `stateSchemaHash` = `HashObj.hashDict(SHA256)` over `SchemaWalker.describeSchema(stateSchema)` — the A7-fixed walker recurses into nested records, so the hash catches nested shape drift (still shape-only; a semantics-only `evolve` change is invisible — documented, alpha-wipe convention per the open question); `encodeState`/`decodeState` are sury `reverseConvertToJsonOrThrow`/`parseJsonOrThrow` wrapped to `None` on failure (an unserializable state skips the write, an undecodable snapshot falls back to full replay — neither fails a command). **(2) Cold path** (`coldReadState`, the in-process-cache-miss arm): when enabled, `latestSnapshot(id)` → hash-gate → `decodeState` → seed `(state, seqNr)` and `replayStream(~fromSeq=seqNr)` folding the **counter from seqNr** (so the OCC total stays correct); absent/drifted/undecodable/read-error all degrade to `(initialState, 0)` full replay with a `logWarn`. Disabled → `Effect.succeed((initialState, 0))` + replay from 0, **zero `latestSnapshot` calls**. Log line: `replay: … (snapshot@N, K delta event(s))` (Step 6's expected marker). **(3) Write trigger**: after a successful append, `maybeWriteSnapshot` fires when `newSeq / interval > oldSeq / interval` (a boundary lies in `(oldSeq, newSeq]`) — **keep-one**, so a batch crossing several boundaries writes just the latest state at `newSeq`. `fireSnapshotWrite` is genuinely fire-and-forget (`let _ = promise->Promise.then(...)->Promise.catch(...)` — logs Ok/Error/throw, never awaited, never fails the command). The warm path (in-process cache hit) skips **both** snapshot read and replay — snapshots only matter cold. **Tests**: new `AggregateSnapshotTest` (**6**) with an OCC-enforcing mock that also records snapshot reads/writes and the replay `~fromSeq`: boundary writes at 10 & 20 (not 25, keep-one → seq-20 survivor); cold read seeds from snapshot and replays only the 10..12 delta; **snapshot-seeded fold ≡ full-replay fold** (20 items, no double-count/gap); schema-drift hash → full replay from 0; write failure doesn't fail the command (event persisted, no snapshot left); **disabled aggregate → (0 reads, 0 writes)** and always replays from 0. Existing 26 aggregate tests unchanged (their behaviors are `snapshot = None`). **Verified**: core **46 suites / 491 tests** (+6), local **475**, aws **139**, all green, zero warnings. **Next**: Step 6 (enable `@@reventless.snapshots(N)` on an example + live SQLite restart smoke), Step 7 (docs).
- 2026-07-03 — **reventless-ppx republished to 1.0.0-alpha.49 — Step 2 gate cleared** (ppx/lockfile/examples). Two-round cutover, all on `alpha`. **Round 1**: bumped the three per-platform `npm/*/package.json` to alpha.49 and pushed `alpha` — the `src/**` change in the Step 2 commit auto-triggered `publish-ppx.yml`, which built + published `reventless-ppx-darwin-arm64` and `-linux-x64` at alpha.49 (verified on the registry). **Round 2**: bumped the thin main `packages/reventless-ppx/package.json` to alpha.49 + its `optionalDependencies` to `^1.0.0-alpha.49`, `pnpm install --lockfile-only` (overlay off → clean 10-line lockfile diff, zero reventless-ui contamination), pushed, and `gh workflow run publish-ppx.yml --ref alpha -f publish=true` published the **main** package. All three now at `latest = alpha.49`. **Example `.res.mjs` regenerated + committed** from the published binary: aggregate behaviors carry `snapshot: undefined` (the `None` default) and DCB translation slices carry `externalSystem` (a second injection that had been pending unpublished) — 26 files, mechanical only, example GWT suites green (catalog 44, ordering 57). **Root-caused the first round's red `Test PPX` job**: the job `dune build`s a fresh binary but `test/run.sh`'s launcher resolves the **installed** per-platform package first (still alpha.46 via the pre-round-2 lockfile), so it tested the *old* binary — my two snapshot assertions and the unrelated `@ref productId` one (a post-alpha.46 feature) all failed for the same stale-binary reason. Round 2's lockfile pin fixed it: the re-run's `Test PPX` went **green (218/0)**, proving the published binary injects correctly. Memory [[feedback_ppx_linux_rebuild]] updated with the launcher-precedence trap (must also copy the fresh binary over `node_modules/@reventlessdev/reventless-ppx-<target>/ppx.exe`, and the CI job's blind spot). **Step 2 is now fully unblocked — Step 5 (callback wiring) can land green.**
- 2026-07-03 — **Step 2 done (code) — config surface + PPX injection; ⚠ needs a reventless-ppx republish before CI can pass** (spec/ppx/core/local/gwt). **(1) Spec**: new `Reventless.Snapshot` (`type config<'state> = {interval: int, stateSchema: S.t<'state>}`) and `Behavior.T` gained the required field `let snapshot: option<Snapshot.config<state>>` — the plan's exact shape. **(2) PPX** (`SnapshotInjection.ml`, hooked into the `@@reventless.behavior` branch, **Aggregate/ folders only** — StateChangeSlice behaviors satisfy a different module type and DCB snapshotting is a non-goal): default-injects `let snapshot = None`; `@@reventless.snapshots(N)` injects `Some({Reventless.Snapshot.interval: N, stateSchema})` — the `stateSchema` reference resolves because reventless-ppx runs before sury-ppx. Three targeted compile errors, all verified live: attribute on a non-Aggregate behavior (tested on a DCB slice), attribute without `@schema type state`, attribute conflicting with a manual `let snapshot`. Idempotent on manual bindings (`has_let_binding` guard). **(3) Hand-written implementors** outside Aggregate/ folders got manual `let snapshot = None`: core's admin `PluginBehavior` (lives under `plugin/lifecycle/` — outside the folder gate; documented inline), the three core aggregate-test behaviors, local's `ItemBehavior` fixture, and gwt's four `Mapping_GWT.FromBehavior`/`AggregateCommandStep` test behaviors. **(4) PPX test suite** (`test/run.sh`, run under `opam exec --switch=5.2.1`): +4 assertions (default injection on the behavior fixture; new `SnappedBehavior` fixture pinning `interval: 25` + the `stateSchema` reference) — **218 passed / 0 failed**. **(5) End-to-end sugar smoke**: `@@reventless.snapshots(50)` on the aggregates example's `Product_Behavior` compiles to `{interval: 50, stateSchema}` and the catalog GWT corpus stays **44/0** through the real runner (attribute then reverted — enabling an example for real is Step 6, after Step 5 makes the config do something). **Verified**: whole monorepo **225 suites / 1749 tests** green with the locally-built PPX (`build:ppx` + copy over `node_modules/@reventlessdev/reventless-ppx-darwin-arm64/ppx.exe` — the per-platform package shadows the `ppx-osx.exe` fallback in the resolution order, worth remembering). **⚠ CI/publish sequencing**: CI compiles with the **published** PPX (alpha.48), which does not inject `snapshot` — every `@@reventless.behavior` aggregate file fails the `Behavior.T` match until reventless-ppx is republished (same situation as the readConsistency rollout). Example `.res.mjs` regeneration (this injection **plus** the already-pending unpublished `externalSystem` injection) is deliberately **not** committed — regenerate and commit those together after the republish.
- 2026-07-03 — **Steps 3 + 4 done — snapshot storage surface, all three backends** (core/local/aws). The adapter contract landed independently of the PPX-blocked Step 2, exactly as sequenced. **(Step 3, core)**: `EventLog.snapshot = {seqNr, state: JSON.t, schemaHash}` + `latestSnapshot`/`writeSnapshot` op types (string-error channel — a snapshot failure must never fail a command, so no typed/retryable errors), added to `EventLog.T.operations`, `EventLog_Adapter.operations`, `EventLog_Operations` (typed passthrough — state stays JSON at this layer; the callback will decode + hash-gate in Step 5), and `EventLog_Builder`. `replayStream` gained the offset — **naming deviation from the draft**: `~fromSeq: int=?` (inclusive, default 0) instead of `afterSeq`, because a snapshot at `seqNr = N` resumes at exactly seq N (seqNr = count of folded events); design snippets updated to match. Optional-arg record fields mean callers are unchanged (`replayStream(id)` still compiles everywhere). All in-repo mocks updated (core aggregate/eventlog fixtures, local `MockEventLogStorage` — the eventlog fixture got a real dict-backed snapshot store so the Operations passthrough is covered). **(4a, InMemory)**: closure dict keyed by id (plain dict — writes are single-threaded fire-and-forget upserts, no Stm); `fromSeq` = index filter (array index ≡ seq, contiguous-from-0 invariant). **(4b, SQLite)**: new `snapshot(log_name, aggregate_id, seq_nr, state, schema_hash)` table, PK `(log_name, aggregate_id)`, `INSERT OR REPLACE` (keep-one), prepared statements; `fromSeq` = `AND seq_nr >= ?` on the existing replay statement. **(4c, DynamoDB — two design deviations from the draft, both documented in source)**: (1) the replay key condition is now `id=:id AND #p BETWEEN :from AND :to` with `:from = pad(fromSeq)` and `:to = "999999999"` — positions are 9-digit zero-padded strings, so the bounded range simultaneously implements `fromSeq` **and excludes the `position = "SNAPSHOT"` side-key row** (`"S" > "9"`), which the old unbounded `id=:id` query would have fed into event decoding; (2) `latestSnapshot` is a separate consistent `GetItem` on `(id, "SNAPSHOT")` rather than the draft's single-partition-query-then-partition — the delta read needs the snapshot's seqNr *before* it can bound the query, and two keyed reads are simpler than a client-side partition split. `writeSnapshot` is an unconditional `PutItem` (keep-one, last-writer-wins is safe — racing writers at the same boundary write identical state). **Stream-feed safety confirmed, not just assumed**: `Util_DynamoDbStream_Runtime.buildJsonEvent'` already drops rows without an `event` column (the DCB FENCE mechanism), so snapshot puts on the streamed table variant never reach event collectors — comment extended, pinned by a test. **Tests**: local `EventLogSnapshotParityTest` (**8**: both backends × absence/round-trip+keep-one/per-id isolation/fromSeq≡full-replay-tail incl. empty-delta), SQLite suite +3 (fromSeq delta, keep-one round-trip, **snapshot survives a db reopen**), aws runtime +6 (query-input bounds default/fromSeq, sentinel-ordering proof, item codec round-trip, malformed-item rejection, snapshot-row-invisible-to-stream-feed). **Verified**: whole monorepo **225 suites / 1749 tests** green, zero warnings. **Next**: Step 2 (config surface — still blocked on the reventless-ppx republish), then Step 5 wires the callback's cold path through `latestSnapshot` + boundary-crossing writes.
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
// replayStream gains an offset so the delta after a snapshot is readable.
// `fromSeq` is INCLUSIVE (replay events with seq_nr >= fromSeq; default 0) —
// a snapshot at seqNr = N resumes with replayStream(id, ~fromSeq=N).
replayStream: ('id, ~fromSeq: int=?) => Stream.t<'event, string, unit>,
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
eventLog.replayStream(id, ~fromSeq=seedSeq)
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

**Complete (2026-07-03).** All seven steps done: the always-on in-process replay cache
(Phase 1); the snapshot storage surface across all three backends
(`latestSnapshot`/`writeSnapshot`/`replayStream(~fromSeq)`); the config surface
(`Reventless.Snapshot`, `Behavior.T.snapshot`, PPX default injection +
`@@reventless.snapshots(N)`, shipped with reventless-ppx alpha.49); the callback wiring
(cold-path snapshot seeding with a `SchemaWalker` hash gate + boundary-crossing
fire-and-forget writes); the reference example (`Product_Behavior`, `snapshots(50)`) with
a passing live SQLite restart smoke; and the component docs. Follow-ups tracked elsewhere:
the SQLite snapshot table's migration story couples to B5's persisted-data-versioning
decision; the two open questions (semantics-only `evolve` drift, cache-capacity knob) are
accepted-for-alpha decisions, not pending work.
