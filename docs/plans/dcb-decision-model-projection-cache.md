# Plan: In-Process Decision-Model Projection Cache

**Analysis**: [dcb-dynamodb-consistency-check.md](../../analysis/dcb-dynamodb-consistency-check.md) — Performance assessment, decision-model-read bullet
**Sibling plan**: [dcb-dynamodb-atomic-append.md](../done/dcb-dynamodb-atomic-append.md)

## Problem

`StateChangeSlice_Callback.handleSingleCommand` ([Callback.res:48-168](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L48-L168)) re-reads the decision model from scratch for every command:

```rescript
dcbEventLog.readStream(~query)
->Stream.runFold((Behavior.initialState, None, 0), …)
```

For high-frequency commands targeting the same entity, every command pays for one DynamoDB query (single tag → strong-consistency base table, multi-tag → composite GSI), full event decode, and full fold from `initialState`. Cost is O(events) per command, regardless of whether the decision model has changed since the last command.

On conflict, the slice's outer retry loop re-runs the same read up to `maxRetries=3` times. A conflicted command pays 4× the read cost of a clean append, on top of the conflict's own latency.

This is a per-Lambda-invocation cost. Lambda warm-instance reuse means the same process often handles many same-entity commands in sequence, and each one re-pays the full read.

## Goals

- Skip the full re-read when the same Lambda instance has recently handled a command for the same query and knows the resulting state.
- Cache hit reduces the read to a delta-only query (`~after = cachedHeadPosition`) — typically returning zero events on the happy path.
- Cache miss falls through to current behaviour. No correctness regression.
- Bounded memory: per-instance LRU with explicit cap.
- Correctness preserved across cache staleness: the fence-based atomic append already detects stale reads and forces a retry. The cache must not subvert this — a cached state used in a retry-after-conflict must be invalidated.

## Non-goals

- Cross-Lambda cache (Redis, ElastiCache, etc.). Those add an out-of-band consistency surface and a network hop. The cheap win is in-process; cross-instance caching is a separate decision.
- Subscribing to a real-time event stream to keep the cache fresh. Reventless has no such primitive in the core slice runtime today, and adding one is much larger scope.
- Caching across slice cold starts. Module-level mutable state survives warm reuse but resets on cold start. That's the appropriate scope.

## Approach

Bounded LRU cache, keyed on serialised query, storing `(state, headPosition)` per slice instance.

### Data flow

```
handleSingleCommand(command):
  query = buildQueryFromCommand(command)
  cacheKey = serialise(query)

  case cache.get(cacheKey):
    Some(cached) =>
      // Delta read: pull only events after cached headPosition
      delta = readStream(~query, ~after=cached.headPosition).fold(...)
      newState = delta.events.foldLeft(cached.state, evolve)
      newHead = delta.lastPosition || cached.headPosition

    None =>
      // Full read (current behaviour)
      (newState, newHead) = readStream(~query).fold(...)

  events = decide(newState, command)
  result = append(events, ~condition={query, after: newHead})

  case result:
    Ok(_) =>
      // Apply produced events to state, update cache
      finalState = events.foldLeft(newState, evolve)
      finalHead = result.position
      cache.put(cacheKey, (finalState, finalHead))

    Error(Conflict) =>
      cache.invalidate(cacheKey)  // stale — let retry refresh
      retry
```

### Why this is safe

- The fence is the only consistency primitive. The cache feeds the *decision*, not the *check*. If the cache is stale, `decide` produces events based on a wrong state, but the conditional append's fence check sees the up-to-date `lastPosition` in DynamoDB and rejects the write → retry → cache invalidated → fresh read.
- The delta read uses `~after=cached.headPosition`, which is strongly consistent on the single-tag path (post `89fe39121`). Any event the previous command wrote is visible to the next read. The cache is a fast path for the read, not a substitute for it.
- After a successful append, the slice knows exactly which events were produced and at what `headPosition`. Updating the cache with these is correct without a re-read.

### When the cache misses

- First command targeting a query in this Lambda instance.
- Query for which the cached entry was evicted (LRU).
- Query whose cached entry was invalidated by a recent conflict.

In all cases, fall through to the existing full-read path.

### When the cache hits (happy path)

Most subsequent commands for the same entity in a warm Lambda. Read becomes:
- Single DynamoDB query with `~after=cachedHead` and `Limit: 1` (or small limit) — almost always returns zero events because no other writer touched this entity between commands handled by the same instance.
- Cost: 1 RCU vs ~N RCU for the full read of N events.

### Why this matters more than profile

The fence design already incentivises co-locating commands for the same entity onto the same Lambda (otherwise you have multi-instance contention on the same fence). Once that routing exists (or even just emerges from API Gateway's connection reuse), per-instance cache hit rates climb sharply for hot entities — the exact case where the read cost matters most.

## Steps

### Step 1 — Add a per-instance LRU primitive

There's no existing LRU in the workspace. Either:
- Add a small dependency (e.g. `lru-cache` is well-trodden), or
- Hand-roll a 50-line LinkedHashMap-style LRU in `reventless-core/src/util/`.

Hand-roll preferred — single use site, one less dep, easy to make ReScript-typed.

```rescript
module Lru: {
  type t<'k, 'v>
  let make: (~capacity: int) => t<'k, 'v>
  let get: (t<'k, 'v>, 'k) => option<'v>
  let put: (t<'k, 'v>, 'k, 'v) => unit
  let invalidate: (t<'k, 'v>, 'k) => unit
  let clear: (t<'k, 'v>) => unit
}
```

### Step 2 — Wire cache into `StateChangeSlice_Callback`

In [`StateChangeSlice_Callback.res`](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res):

- Add module-level `let cache = Lru.make(~capacity=100)` (capacity tunable per slice via spec).
- In `handleSingleCommand`, key on a stable serialisation of `query` (e.g. JSON-stringify with sorted keys).
- Branch on cache hit/miss as described above.
- After successful append: fold produced events into `(state, newHeadPosition)` and `Lru.put`.
- After error: `Lru.invalidate(cacheKey)` before the retry, so the retry takes the full-read path.

### Step 3 — Tests

In existing slice GWT tests (in-memory adapter):

- Two consecutive commands targeting the same entity → second command's read returns zero events from the in-memory adapter (the first command's write is in the cache; delta read is empty).
- Concurrent commands targeting the same entity from two simulated instances → both cache independently, both hit fence conflict, retry refreshes correctly.
- Conflict path → cache is invalidated, retry triggers a full read.

In new unit tests (`tests/components/StateChangeSlice/CacheTest.res` or similar):

- LRU eviction: 101 distinct queries against a capacity-100 cache → LRU entry evicted.
- Cache hit returns same `(state, headPosition)` tuple as a fresh fold of the same events.

### Step 4 — Configuration knob

Make capacity configurable per slice spec (default 100). Slices with very wide entity sets (e.g. log aggregation) may want 0 (disabled) to avoid memory pressure. Slices with narrow hot entities may want larger caches.

```rescript
// In a spec
let projectionCacheCapacity = Some(500)  // None disables the cache
```

### Step 5 — Metrics

Add CloudWatch metrics:
- `DcbDecisionModelCacheHit` / `DcbDecisionModelCacheMiss` counters per slice.
- `DcbDecisionModelDeltaEventCount` histogram (number of events returned by delta reads — should be near-zero on healthy hits).

If `Miss` dominates `Hit`, the workload doesn't benefit and the cache is just memory pressure. Surface this signal to operators.

### Step 6 — Document

Update [`docs/analysis/dcb-dynamodb-consistency-check.md`](../../analysis/dcb-dynamodb-consistency-check.md) §"Performance assessment" decision-model bullet to mark addressed (with the caveat that it requires warm-instance reuse to pay off). Move plan to `done/`.

## Open questions

- **What happens for multi-tag queries where the slice's `query` array has many items?** The cache key is the full serialised query — same shape, same key. But subtly different command instances may produce slightly different queries (e.g. filtering on different `customerId` values). Each gets its own cache entry. With 100-capacity LRU and a workload spanning thousands of distinct customers, hit rate is low. Profile before tuning capacity.
- **State serialisability.** The cache stores live ReScript values, not serialised state. They're shared by reference across cache hits — the slice's `evolve` function must not mutate state in place. Reventless conventions already favour immutable updates; document and verify.
- **Cache poisoning under bug scenarios.** A `decide` that produces events but then fails to append (network error, not conflict) leaves the cache un-updated, which is correct. A `decide` that produces correct events but the operator manually deletes them from DynamoDB out-of-band leaves the cache pointing at events that don't exist — but the next conditional append will fence-conflict (real `lastPosition` in DynamoDB is older than cached `headPosition`), invalidate, and recover. Out-of-band manipulation is already an edge case; the cache doesn't make it worse.
- **TTL on cache entries.** LRU alone may keep stale entries warm forever in low-eviction workloads. Consider an additional time-based eviction (e.g. 5 minutes). For workloads where conflict rates are low, this is overcautious; for workloads with infrequent commands per entity, it prevents pathological cases. Default off; revisit if metrics show stale-cache surprises.

## Status

**Core shipped — 2026-06-20** (roadmap Phase 4). Steps 1–3 and the Step 6 analysis-doc update are done; Steps 4 (per-slice capacity knob) and 5 (CloudWatch hit/miss metrics) are deferred follow-ups.

**What shipped:**
- **Step 1 — LRU primitive.** Hand-rolled, sealed `Lru` in [`reventless-core/src/util/Lru.res`](../../reventless/core/src/util/Lru.res) (+ `.resi`), recency via JS-Map insertion order, `capacity <= 0` disables. Unit-tested in [`tests/util/LruTest.res`](../../reventless/core/tests/util/LruTest.res) (get/put/overwrite/invalidate/eviction/LRU-recency/101-vs-100/disabled).
- **Step 2 — wired into `StateChangeSlice_Callback`.** Module-level cache per functor instantiation (per slice, per warm Lambda), hardcoded capacity 100. On a cache hit the read is seeded `~after=cachedHead` (delta); on conflict the retry re-seeds from the just-read snapshot so each retry is also a delta read; terminal failure invalidates.
- **Design change vs. the pseudocode below (important).** The cache stores the **decided-on state and the read head — NOT the produced events folded in, and NOT `append`'s returned position.** Two reasons the original "fold produced events into cached state, cache `append`'s position" sketch is unsafe: (1) `evolve` consumes `Spec.consumedEvent` but `decide` produces `Spec.event` — different ReScript types, no generic fold; (2) `append` returns the batch **base** position on DynamoDB but the batch **max** in-memory, so `~after=position` would re-read the batch tail on DynamoDB (multi-event append → double-count). Caching `(decisionState, readHead)` sidesteps both: the next command's delta read picks up our just-appended events (their position is always `> readHead` on both backends) and folds them itself. Correctness still rests entirely on the fence.
- **Step 3 — tests.** `LruTest` (above) + three projection-cache scenarios in [`DcbStateChangeSliceTest.res`](../../reventless/core/tests/dcb/DcbStateChangeSliceTest.res): warm same-entity command reads only the delta (`readAfters == [None, None, Some("1")]`), a different entity stays a cold full read, and a forced conflict re-seeds so the retry reads the delta. The mock storage records each read's `~after`. `resetCache()` (added to the callback interface) is flushed in `beforeEach` since the mock storage is wiped out from under the persistent cache each test.
- **Step 6 — docs.** `dcb-dynamodb-consistency-check.md` §Performance assessment + §4 bullets updated to mark the decision-model read cost addressed.

**Deferred follow-ups.** Both are **tuning/observability, not correctness** — the cache is already live and safe (the fence is the consistency primitive; a stale entry only ever costs a rejected append + retry). They are complementary: Step 5 *diagnoses* a mis-served slice, Step 4 *acts* on it (cap it to 0 / raise it). Neither is urgent — they earn their cost only once a real workload is shown to be mis-served by the flat 100.

- **Step 4 — per-slice capacity knob.** Today capacity is hardcoded at 100 for every slice ([`StateChangeSlice_Callback.res:129-135`](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L129-L135), *"Capacity is fixed at 100 entries; a per-slice knob is a future refinement"*). One number for everyone is wrong at both extremes:
  - A slice over a **wide entity set** (log-style aggregation touching millions of distinct entities) thrashes the 100 slots → near-zero hit rate, pure memory pressure. It wants capacity **`0`** (disabled).
  - A slice with a **narrow set of hot entities** could profitably hold far more → it wants, say, **`500`**.

  Implementation mirrors the existing `readConsistency` / `authorization` / `visibility` levers: add `let projectionCacheCapacity: option<int>` to `StateChangeSlice.Spec` (`None` = disabled), thread it into the callback in place of the literal `100`, and add a **new PPX pass** to auto-inject the default into every slice spec (plus a file-level override attribute), just like `ReadConsistencyInjection.ml`. **The cost is the release coupling, not the code:** adding a *required* field to `StateChangeSlice.Spec` that only the new PPX injects means every slice spec needs the new binary to compile, so — exactly as with the Phase 5a `readConsistency` follow-up — it cannot pass CI until **reventless-ppx is republished at a new version with the lockfile updated**. That's why it wasn't bundled opportunistically. The hardcoded 100 is a sane default until a slice needs tuning or opt-out.

- **Step 5 — cache hit/miss metrics.** No way today to see whether the cache helps a given slice in production. Add per-slice signals: `DcbDecisionModelCacheHit` / `DcbDecisionModelCacheMiss` counters and a `DcbDecisionModelDeltaEventCount` histogram (near-zero on healthy hits). If `Miss` dominates `Hit`, the cache is just memory pressure for that workload — the operator's cue to set its capacity to `0` (Step 4). **The primitive this note originally called for now exists:** Phase 5a shipped the provider-neutral emitter [`Metrics.res`](../../reventless/core/src/util/Metrics.res) (one structured JSON line per occurrence, no `_aws`/EMF vocabulary in core) and the AWS-side CloudWatch `LogMetricFilter` translation (used today for `AppendRetry`/`AppendConflict`). So this is now the **cheaper, un-coupled** follow-up — emit two more metric kinds from the cache get/put sites and add two more metric filters, following the established pattern; no Spec change, no PPX/republish. Land when operators need the hit-rate signal (and it's the diagnostic that would tell us whether Step 4 is even worth its release cost).

---

_Original plan (retained for reference; supersede the §Approach pseudocode with the shipped design noted above):_
