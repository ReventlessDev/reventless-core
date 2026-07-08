# DCB composite-fence burst contention — residual after the single-composite-fence fix

**Status:** DONE 2026-07-08 — root cause was a runtime *wiring* gap, not the fence
construction. The single-composite-fence collapse (`c2a123195`) is correct; the
**deployed Lambda entry point never threaded `partitionTag` into the DynamoDB
`append`**, so the collapse (gated on `partitionTag = Composite`) was dead code in
production and every composite slice fell back to per-member fences. Fixed by
threading `partitionTag` + `crossPartitionTagKeys` in
[`DcbCommandTopicEntryPoint.mjs`](../../reventless/reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs).
See **Resolution** at the bottom.

**Status (original):** Proposed (evidence-gated, opened 2026-07-08)
**Supersedes the "live confirmation" tail of:** [done/dcb-hot-tag-fence-contention.md](done/dcb-hot-tag-fence-contention.md)
(that plan closed the per-member→single-composite-fence collapse and asked for *"passive
live confirmation on the next alpha deploy"*, adding: *"If a different hot-fence shape ever
surfaces, open a fresh evidence-gated item rather than reopening this."* — this is that item.)

## Summary

The shipped fix (`c2a123195`, `reventless-aws@3.0.0-alpha.182`) collapsed a composite
partition's **per-member** fences into a **single synthetic composite fence**
(`makeCompositeFenceTag`), proven in the integration suite (distinct composite entities
sharing a low-cardinality prefix no longer conflict). **Live confirmation on a deploy-sync
burst FAILS anyway:** wide-composite StateChangeSlice appends still go **0/N under the
burst**, retries exhausted, so their read models never populate.

## Live evidence (2026-07-08)

Deploy-time sync workload: StateChangeSlices with a `@compositePartitionTag` over
`{environment, platformName, pluginName, componentName}` (4-tag) and
`{…, resourceName}` (5-tag), driven by a plugin deploy fan-out.

- **Deployed code has the fix:** the resolving `reventless-aws` is `alpha.184` (> 182);
  `DcbEventLogStorage_DynamoDb_Runtime.res` carries the `makeCompositeFenceTag` collapse
  ("A Composite partition collapses to a single synthetic composite fence tag").
- **Commands + events are fine:** handler logs `generated command: SyncComponent/SyncResource`
  → `produced 1-2 event(s): [ComponentAdded / ResourceAdded(...)]`.
- **Appends never persist:** `append failed, retrying 1/3…3/3` → `append failed, retries
  exhausted: conflict: condition check failed`. **Burst tally: 39–75 retries-exhausted, 0
  successes; read models stay empty.**
- **The transaction shape shows multiple hot fences remain:**
  ```
  DCB append failed: Transaction cancelled … cancellation reasons
  [None, TransactionConflict, TransactionConflict, TransactionConflict, None, None]
  ```
  A single `SyncResource` append's `TransactWriteItems` has **6 items, 3 of which
  `TransactionConflict`.** If the composite partition truly collapsed to *one* fence, a
  same-plugin fan-out of *distinct* composite entities should contend on **at most** the
  event/position items, not 3 fence items. Three conflicting items per append is the
  signature of **≥3 fence writes still keyed on shared, low-cardinality values** (or of
  query-clause / cross-partition-carrier fences that the composite collapse did not cover).

### Ruled out (so this is not a false alarm)

- **Tag misalignment (consumer-side):** the composite-read guard (`validateCompositeReads`
  / "silently miss") fires **0×** live — the event tag set equals the query tag set
  (the consumer already dropped a stray `Id`-suffixed scalar from the DCB tag set). Not a
  read/write scope mismatch at the slice level.
- **Split Effect runtime:** the handler bundle was running two `effect` versions
  (`3.21.2` code on a `3.21.1` runtime); deduped to a single `effect@3.21.2`, the skew
  warning is gone (0), and the append conflict is **unchanged** (39/0). Not an Effect-runtime
  interop bug.

So with aligned tags, a single Effect runtime, and the composite-fence fix deployed, the
appends still contend to zero throughput — pointing at the fence construction for wide
composite slices under a burst, in `buildConditionalTransactItems` /
`DcbEventLogStorage_DynamoDb_Runtime.res`.

## Hypotheses for core to confirm (pick from the transaction trace)

1. **The composite collapse isn't the only fence source.** The 6-item / 3-conflict shape
   suggests additional conditional writes beyond the one composite fence — e.g. composite
   **query-clause** fences (the multi-tag read clause), a **cross-partition carrier** bump,
   or a per-member `eventPartitionTags` `Composite` branch still contributing member fences
   on the *bump* path even though the read path collapsed. Enumerate exactly which of the 6
   `TransactWriteItems` are fences and on what keys for one `SyncResource` append.
2. **The collapsed composite fence is itself shared across the burst.** If
   `makeCompositeFenceTag` keys on a prefix (not the full high-cardinality composite value)
   for the 4/5-tag case, every command in a same-plugin fan-out bumps the same fence →
   hot. Verify the synthetic fence key is the *full* composite value, not a prefix.
3. **Retry budget vs burst width.** Even correctly-scoped fences serialize; a wide
   synchronous fan-out with a 3-retry inner loop may simply exhaust retries before the
   queue drains. If (1)/(2) are clean, widening/backing-off the retry or serializing the
   append queue per boundary is the lever.

## Asks

- Trace one `SyncResource` append's `TransactWriteItems` in the current runtime and
  classify each of the 6 items (event / position / fence-on-key-X). Confirm whether >1
  fence is written and on which keys.
- Fix the fence construction so a same-prefix, distinct-composite-entity fan-out writes at
  most one high-cardinality fence per append (extend the Phase-0 fence-scope = read-scope
  invariant to the bump path for `Composite` partitions).
- Re-run the DCB integration suite with a **burst** of distinct composite entities sharing
  a low-cardinality prefix (the existing test proves pairwise non-conflict; add the N-way
  concurrent-burst case that reproduces `[…TransactionConflict…]`).

## Acceptance

- A same-plugin deploy fan-out of distinct composite entities appends with **0 retries
  exhausted** (or bounded, converging) and all events persist.
- Integration test: N-way concurrent burst on a shared-prefix composite partition converges.
- (Downstream, out of scope here) the consuming deploy-sync read models populate and stay
  populated across redeploys.

## Resolution (2026-07-08)

**Root cause — a wiring gap, exactly hypothesis (1).** The `c2a123195` collapse in
`DcbEventLogStorage_DynamoDb_Runtime.res` is correct, and the deploy-time adapter
[`DcbEventLogStorage_DynamoDb.make`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb.res)
threads `~partitionTag` + `~crossPartitionTagKeys` into `append`. But the **deployed
StateChange command Lambda** does not use that maker — it builds its own storage ops
in [`DcbCommandTopicEntryPoint.mjs`](../../reventless/reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs),
and it was calling `append(resolvedTable)` / `read(resolvedTable)` /
`readStream(resolvedTable)` — dropping **both** optional args. So at runtime
`partitionTag` defaulted to `None`, the collapse's `Some(Composite(spec))` guard was
never hit, and a composite slice's single multi-tag decision clause was fenced
**per member** (one conditional `Update` per composite member at `after=Some`).

This reproduces the live trace precisely: a `SyncResource` append =
`1 event Put + 5 member fence Updates` = **6 items**, of which the three shared
low-cardinality prefix members (`environment`, `platformName`, `pluginName`) go hot
under the deploy fan-out → `[None, TransactionConflict×3, None, None]` → retries
exhausted, 0 successes. The entry point already re-derived `crossPartitionTagKeys`
(via `deriveEffectiveScope`) for the *decision-query builder* but never for the
*storage ops* — and never derived `partitionTag` at all.

**Fix (code-only, no PPX / no republish):** in `buildHandlersForConfig`, load the
slice modules first, then derive `partitionTag` with `DcbTag.derivePartitionTag`
over the produced event schemas (mirroring `Dcb_Builder.res`) and thread it plus
`crossPartitionTagKeys` into the DynamoDB `append`/`read`/`readStream`:

```js
read:       read(resolvedTable, crossPartitionTagKeys),
append:     append(resolvedTable, partitionTag, crossPartitionTagKeys),
readStream: readStream(resolvedTable, crossPartitionTagKeys),
```

`derivePartitionTag` is wrapped in a try/catch that falls back to the old untagged
behaviour (rather than crashing cold start) on a misconfigured spec the deploy would
already have rejected. The Postgres branch is unaffected — its `opsFor` ignores
`partitionTag` (advisory/row locks handle the boundary). This also closes a latent
cross-partition *read-routing* gap: single-tag `@crossPartition` reads on the
deployed path were routing to a base-table partition lookup instead of the per-tag
GSI, because `crossPartitionTagKeys` never reached `read`/`readStream`.

**Tests (green against DynamoDB Local, Docker).**
- New integration regression in
  [`DcbCommandTopicEntryPoint_IntegrationTest.res`](../../reventless/reventless-aws/tests/integration/DcbCommandTopicEntryPoint_IntegrationTest.res)
  with a composite-partition fixture (`EpCompositeSlice`, `{environment,
  resourceName}`): an **N-way concurrent burst** of distinct resources sharing the
  `environment` prefix — all commit (`CommandAccepted`), and a fence-row scan
  proves the only fences written are the synthetic `fence#__dcb_composite__:…`
  (one per entity), with **no** per-member `fence#environment:…` rows.
- Verified as a genuine guard: reverting the `append` thread turns the test red
  (per-member fence rows reappear).
- Full suites: reventless-aws unit **208/208**; DCB integration **16/16**.

**Acceptance met:** a same-prefix, distinct-composite-entity burst appends with 0
retries exhausted and all events persist; the N-way burst integration case
converges. The remaining downstream item (deploy-sync read models repopulating on
alpha) is passive live confirmation on the next deploy.

**Out of scope (noted):** `MCP_Lambda.res` calls
`DcbEventLogStorage_DynamoDb_Runtime.read(table)` without `crossPartitionTagKeys` —
the same read-routing gap, but read-only MCP query tooling, not the OCC append path.
Track separately if a `@crossPartition` MCP query is ever needed.
