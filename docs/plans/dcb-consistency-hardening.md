# Plan: DCB Consistency-Check Hardening (roadmap)

**Status**: Proposed — derived from analysis [dcb-consistency-check-issues.md](../analysis/dcb-consistency-check-issues.md) (2026-06-20)
**Nature**: umbrella roadmap. Sequences the open correctness, cost, and robustness items from the analysis. Net-new work is detailed inline; items already covered by a focused plan are referenced, not duplicated.

## Phasing rationale

Order = correctness → verification harness → durable cost wins → robustness guards → profile-gated tuning. Verification (Phase 1) comes early because nothing else here can be *trusted* without a real-DynamoDB test of the fence path — local backends don't use fences, so unit tests only assert transaction *shape*, not DynamoDB *behaviour*.

| Phase | Item | Analysis ref | Class | New work? | Existing plan |
|---|---|---|---|---|---|
| 0 | Fence-scope = read-scope | Issue 1 | Correctness | shipped | [dcb-fence-scope-alignment](dcb-fence-scope-alignment.md) |
| 1 | DynamoDB integration test | Issue 3 | Verification | **done** | [dcb-dynamodb-atomic-append-integration-test](done/dcb-dynamodb-atomic-append-integration-test.md) |
| 2 | `after=None` create-race | Issue 2 | Correctness | **yes** | — (detailed below) |
| 3 | Down-project per-tag GSIs to `KEYS_ONLY` | Perf/cost lever #1 | Cost | **done** | — (detailed below) |
| 4 | Decision-model cache | Perf/cost lever #2 | Cost | **core done** | [dcb-decision-model-projection-cache](dcb-decision-model-projection-cache.md) |
| 5 | Robustness guards | Issues 4, 5, 6, 9, 12 | Robustness | **5,12 done; 4,6,9 open** | — (detailed below) |
| 5 | Drop vacuous query-clause type combos | Issue 14 | Cleanup | **done** | — (Phase 5 below) |
| 5 | Opt-in strong reads | Perf/cost lever #3 | Cost | **yes** | — (detailed below) |
| 6 | Hot-tag sharding / selective bump | Issue 10 | Throughput | **evidence in (2026-07-07)** | [dcb-hot-tag-fence-contention](Backlog/dcb-hot-tag-fence-contention.md) |
| 6 | Monotonic positions | Issue 7 | Cleanup | no | [dcb-monotonic-position-generation](Backlog/dcb-monotonic-position-generation.md) |
| 7 | Cross-partition secondary-tag reads | Issue 13 | Capability | **done (source; mjs/CI pending ppx republish)** | [dcb-phase7-cross-partition-reads](done/dcb-phase7-cross-partition-reads.md) |

---

## Phase 1 — DynamoDB integration test (Issue 3) — **DONE (2026-06-20)**

Implemented per [dcb-dynamodb-atomic-append-integration-test](done/dcb-dynamodb-atomic-append-integration-test.md). The fence path now has end-to-end behavioural coverage against a real DynamoDB engine (DynamoDB Local via Docker), proving Phase 0's fix and giving every later phase a harness.

**What shipped**:
- `reventless/reventless-aws/tests/integration/DcbEventLogStorage_DynamoDb_IntegrationTest.res` (+ `DcbIntegrationHarness.res` for `CreateTable`/`DeleteTable`/fence helpers).
- `docker-compose.dynamodb-local.yml` + `scripts/run-integration-tests.sh` (boots the sidecar, waits, runs, tears down; **skips cleanly when Docker is absent** so it's safe in CI's existing continue-on-error step and on dev machines).
- Root `jest.integration.config.js` + `jest.integration.setup.cjs` (points the SDK at the local engine via `AWS_ENDPOINT_URL_DYNAMODB` — **no binding changes**). Wired to the real `pnpm run test:integration`; default `pnpm test` stays engine-free (integration dir is `testPathIgnorePatterns`-excluded).
- **Polyfill**: added `structuredClone` to `jest.setup.cjs` (mirrors the existing `crypto` polyfill). The AWS SDK's error-response deserializer calls it; without it a real `TransactionCanceledException` surfaced as `"structuredClone is not defined"` and masked the conflict — i.e. the fence path was untestable in Jest's VM sandbox until this was added.

**Scenarios covered** (the four regression cases + OCC primitives):
1. Sync `P5`; order `O1[P5]` → Ok; order `O2[P5]` (diff customer + orderId) → **Ok** (Issue 1 regression). ✓
2. Same product, two concurrent orders → both Ok (no `productId` contention). ✓
3. A concurrent re-sync of `P5` advancing the fence past the order's read → conditional `productId` check **still conflicts** (OCC preserved). ✓ *(uses a deterministic `setFence` rather than racing a second append — same-millisecond writers can tie on UUID order, analysis Issue 7).*
4. Register customer `C`, place an order carrying `C` as a secondary tag, then `ChangeEmail(C)` → Ok (placing the order no longer poisons the customer slice). ✓
5. Fresh first-writer (`after=None`) seeds the fence. ✓
6. Two concurrent commits at the same `after` never both win (safety; raw layer may cancel both — the slice callback's 3-retry loop is what guarantees a single winner in prod). ✓
7. A chain of compatible commits all succeed. ✓
8. A failed fence condition aborts the whole multi-tag transaction (atomic rollback — the rejected event is not written). ✓

Tagless-rejection and 100-item-limit round-trips are already covered by the unit suite (`DcbEventLogStorage_DynamoDb_RuntimeTest.res`), so they are not duplicated here.

Gate: Phases 2–3 must add their scenarios to this suite before merge.

## Phase 2 — Close the `after=None` create-race (Issue 2) — **DONE (2026-06-20)**

Shipped **option B** (per-(eventType, partition) create guard). 2A investigation showed option A insufficient for the default sync path; B closes the hole there too and sidesteps Issue 4. Implementation in `DcbEventLogStorage_DynamoDb_Runtime.res` (`buildCreateGuardUpdate` + the `after=None` branch of `buildConditionalTransactItems`). Verified: unit shape tests (4) in `DcbEventLogStorage_DynamoDb_RuntimeTest.res`; integration scenarios (two concurrent first-writers → at most one wins, no duplicate persisted; subset-event-type writer → no false conflict) in the Phase 1 suite (10 cases, green). Full details in analysis Issue 2 § "Fix (shipped 2026-06-20)". The reference material below is retained for context.

**Goal**: two concurrent first-writers to the same entity must not both succeed.

**The tension (must resolve first).** The naive fix — at `after=None`, make the partition-tag fence a conditional `Update` gated on `attribute_not_exists(lastPosition)` — reintroduces the exact false conflict that motivated the unconditional fallback: a slice that reads a *subset* of the event types on a shared partition (e.g. reads only `NameChanged` on a `productId` partition that already has a `ProductAdded`) sees zero matching events, `after=None`, and its `attribute_not_exists` fails because a *different* event type already created `fence#productId`. This is Issue 4 (per-tag, not per-(tag, event-type) fences) resurfacing.

**Decision to make (pick one; recommend B then A if needed):**

- **A — Rely on upstream FIFO per-entity serialization, document + test.** If `StateChangeSlice` commands for the same entity share a FIFO `messageGroupId` (verify in `CommandTopic`/SQS wiring), two same-entity creates can never run concurrently, so the hole is theoretical. Action: confirm the grouping, document the guarantee at `appendConditional`'s `after=None` branch, and add an integration test that drives two same-entity creates and asserts serialization. **Cheapest; do this first and confirm whether it fully closes the hole.**
- **B — Type-aware creation guard.** When the `after=None` writer's query restricts event types (the common case), emit a `ConditionCheck`/`Update` on a guard item keyed by the producing event type — e.g. `id="create#<eventType>#<key>:<value>"` gated on `attribute_not_exists` — so creation of *that* event type for *that* entity serializes without colliding with other types on the partition. Adds one item to first-writes only. Closes the hole even without FIFO, and sidesteps Issue 4.

**Phase 2A investigation result (2026-06-20): Option A is insufficient — escalate to B (or the partition-tag `attribute_not_exists` variant).** The DCB command-topic wiring ([`reventless-aws/.../Plugin.res`](../../reventless/reventless-aws/src/components/Plugin.res) → `CommandTopicChannel.SQS_Sync` for `DcbCommandTopicChannel`, `SQS_Async` for `DcbCommandTopicChannelAsync`):

- **Async slices** (`@@reventless.async`) → `CommandTopicChannel_SQS_Async`, a **FIFO** queue with `messageGroupId = safeGroupId(commandJson.id)` ([`Util_SQS_Runtime.res:43`](../../reventless/reventless-aws/src/util/Util_SQS_Runtime.res#L43)), and for DCB slice commands `commandJson.id` **is the entity/partition id** ([`StateChangeSlice_Callback.res:108`](../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L108)). So same-entity async creates **are** serialized — the hole is closed for them.
- **Sync slices (the default)** → `CommandTopicChannel_SQS_Sync`, a **standard (non-FIFO)** queue whose `publishJsonsAndWait` runs the handler **inline** in the AppSync resolver invocation (Single strategy) or fire-and-forgets to standard SQS (PerAggregate). Neither serializes per entity. Two concurrent first-writers to the same entity therefore both read `after=None` and both append — **the create-race is real on the default path.**

Action taken: documented the async/FIFO guarantee here and in analysis Issue 2. Remaining work = implement B (or partition-tag `attribute_not_exists`) with the red→green create-race integration test below, guarded by the subset-event-type false-conflict case.

**Files**: `DcbEventLogStorage_DynamoDb_Runtime.res` (`buildConditionalTransactItems`, `after=None` branch).

**Tests (TDD, same red→green flow as Phase 0)**:
- Unit: at `after=None`, the built transaction asserts existence on the create guard (shape test) — red before, green after.
- Integration (Phase 1 harness): two concurrent creates of the same entity → exactly one succeeds; a subset-event-type slice on a shared partition does **not** false-conflict.

**Risk**: medium — touches the idempotency fallback. Guard with the subset-event-type integration case explicitly.

## Phase 3 — Down-project per-tag GSIs to `KEYS_ONLY` (cost lever #1) — **DONE (2026-06-21)**

**Shipped (2026-06-21).** Per-tag `tag_<key>` GSIs are now provisioned `KEYS_ONLY`; `tag_composite` stays `ALL`. Changes:
- The deploy-time GSI builder ([`DcbEventLogStorage_DynamoDb.res`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb.res)) now picks the projection per index via a pure predicate `indexKeepsFullProjection` (only `tag_composite` → `ALL`, else `KEYS_ONLY`). The predicate lives in the runtime module so it is unit-testable without the Pulumi deploy layer. *(The projection type was always set in the AWS storage maker, not `Dcb_Builder.res` — that builder only assembles the index-name list, which is unchanged.)*
- Deleted the orphaned `queryBySingleTag` / `queryBySingleTagStream` from the adapter runtime (zero callers; they assumed a full GSI projection). `tagToAttributeName` and the per-tag attribute writes in `toItem` are retained (they populate the `KEYS_ONLY` index keys). Phase 7's cross-partition read will reintroduce a `Query`(keys) → `BatchGetItem`(payloads) variant.
- Tests: `Runtime.indexKeepsFullProjection` unit guard (2 cases; AWS suite green at **128**). The integration harness ([`DcbIntegrationHarness.res`](../../reventless/reventless-aws/tests/integration/DcbIntegrationHarness.res)) now creates per-tag GSIs `KEYS_ONLY` via the **same predicate**, so the Phase 1 scenarios (single-tag base-table reads + composite reads) exercise the production projection. Deploy-time Pulumi wiring is type-checked by the build, not unit-tested (same posture as the Phase 5a metric filter).
- **Migration**: changing a GSI's projection type requires GSI recreation, so the alpha `DcbEventLog` tables must be **wiped + recreated** on next deploy (prefer wipe over migration per repo convention; coordinate with the Phase 0 fence-row wipe). No data-migration code — alpha event data is disposable.

The reference material below is retained for context.

**Decision (2026-06-21): down-project to `KEYS_ONLY`, do not remove.** The per-tag GSIs (`tag_<key>` per tagged field) have zero readers today, but Phase 7 (cross-partition secondary-tag reads — [analysis Issue 13](../analysis/dcb-consistency-check-issues.md#issue-13--no-single-tag-cross-partition-secondary-tag-read-capability-gap)) is now in scope as a future capability. Full removal would foreclose Phase 7 without a GSI rebuild *and* a fence-model reconciliation; `KEYS_ONLY` cuts the storage multiplier (no event payloads duplicated per GSI) and most of the per-write WCU, while leaving the index queryable via a `Query → BatchGetItem` round-trip when Phase 7's read path lands. Expected Phase 7 reads are bounded (`Limit:N+1` count-bounded reads for capacity invariants) and benefit from the Phase 4 decision-model cache, so the extra hop is acceptable.

**Goal**: cut the storage multiplier and most of the per-write WCU on the per-tag GSIs while preserving Phase 7 optionality.

**Finding**: the table provisions one `tag_<key>` GSI **per tagged field** plus `tag_composite`, all `projectionType: ALL` ([`DcbEventLogStorage_DynamoDb.res:19-30`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb.res#L19-L30); index list built in [`Dcb_Builder.res:135-154`](../../reventless/reventless-core/src/components/Dcb/Dcb_Builder.res#L135-L154)). Single-tag reads use the **base table** (`queryByPartitionKeyStream`); composite reads use `tag_composite`. The per-tag GSIs' only readers — `queryBySingleTag` / `queryBySingleTagStream` — have **zero callers** (orphaned by `fc4c1f493` "primary-tag partitioning"). So today they pay the full `ALL`-projection write/storage cost with no read benefit.

**Steps**:
1. **Verify no out-of-adapter consumer** queries the per-tag GSIs: grep the whole repo (EventCollector, admin, MCP, QueryDb, debugging tooling) for `tag_<key>` index-name usage and direct `QueryCommand` with `indexName`. Confirm the EventTopic stream consumer reads the base-table stream, not a GSI.
2. **Down-project the per-tag GSIs** in [`Dcb_Builder.res`](../../reventless/reventless-core/src/components/Dcb/Dcb_Builder.res#L135-L154) from `ALL` to `KEYS_ONLY`. Keep `tag_composite` at `ALL` — composite reads return events directly from that index.
3. **Delete the now-orphaned `queryBySingleTag` / `queryBySingleTagStream`** in the adapter — they query the GSI directly and assume the full event payload (`ALL`). Phase 7 will reintroduce a `queryBySingleTagCrossPartition` variant that does `Query` (keys) → `BatchGetItem` (payloads, against the base table).
4. **Keep the `tag_<key>` attribute writes in `toItem`** — they populate the index keys and are required for `KEYS_ONLY` to remain queryable.
5. **Migration**: changing a GSI's projection type requires GSI recreation → wipe+recreate the alpha DcbEventLog tables (prefer wipe over migration per repo convention; coordinate with the Phase 0 fence-row wipe).

**Tests**: unit-assert the generated `globalSecondaryIndexes` use `KEYS_ONLY` for per-tag GSIs and `ALL` for `tag_composite`; integration smoke (Phase 1) that single-tag (base-table partition) and composite reads still work post-change.

**Risk**: low — shrinking unused indexes and removing dead read paths; the migration is the only real risk surface.

## Phase 4 — Decision-model cache (cost lever #2) — **CORE DONE (2026-06-20)**

Per [dcb-decision-model-projection-cache](dcb-decision-model-projection-cache.md): the slice now folds from a cached `(decisionState, readHead)` and reads only events after the cached head → O(history) read cost becomes O(delta), cutting the per-event `decode` CPU. No slice-contract change.

**What shipped** (Steps 1–3 + Step 6 docs): a sealed in-process LRU ([`reventless-core/src/util/Lru.res`](../../reventless/reventless-core/src/util/Lru.res)) wired into `StateChangeSlice_Callback` (capacity 100, per slice, per warm Lambda). Cache hit → delta read; conflict → re-seed so each retry is also a delta read; terminal failure → invalidate. Tests: `tests/util/LruTest.res` + three projection-cache scenarios in `tests/dcb/DcbStateChangeSliceTest.res` (full reventless-core suite green at 419, local DCB suite green at 35).

**Key design correction** over the plan's original pseudocode: the cache stores the *decided-on state and the read head* — **not** the produced events folded in, and **not** `append`'s returned position. Folding produced events is impossible (`evolve` takes `consumedEvent`, `decide` produces `event` — distinct types), and `append` returns the batch *base* on DynamoDB vs. the batch *max* in-memory (so `~after=position` would re-read the batch tail on DynamoDB). Caching `(decisionState, readHead)` sidesteps both — the next command's delta read picks up our just-appended events itself (their position is always `> readHead`). Correctness still rests entirely on the conditional-append fence.

**Deferred follow-ups**: Step 4 (per-slice capacity knob — needs `projectionCacheCapacity` threaded through `StateChangeSlice.Spec` + PPX auto-injection) and Step 5 (CloudWatch hit/miss metrics). Hardcoded 100 is the interim default.

## Phase 5 — Robustness guards & opt-in strong reads

Small, mostly independent items; land opportunistically.

### Phase 5a — Opt-in strong reads + contention metric (cost lever #3) — **DONE (2026-06-21)**

Shipped: eventual-first / strong-on-retry decision reads (core), a provider-neutral retry/conflict metric signal (core), and CloudWatch metric filters (AWS). The per-slice *force-strong/force-eventual* build-time override (PPX follow-up) is now **implemented (2026-06-21)** — see below.

**Per-slice strong-read override — implemented (2026-06-21), pending PPX release.** A build-time `readConsistency` mode per StateChangeSlice, mirroring `authorization`/`visibility`:
- New `Reventless.ReadConsistency.t` ([`reventless-spec/src/types/ReadConsistency.res`](../../reventless/reventless-spec/src/types/ReadConsistency.res)) with three cases: `EscalateOnRetry` (default — eventual first, strong on retry), `AlwaysStrong` (known-hot slices), `AlwaysEventual` (cost-sensitive, low-contention).
- New required field `let readConsistency: ReadConsistency.t` on `StateChangeSlice.Spec`. The callback's `strongConsistency` is now `switch Spec.readConsistency { EscalateOnRetry => retries < maxRetries | AlwaysStrong => true | AlwaysEventual => false }` ([`StateChangeSlice_Callback.res`](../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res)). Correctness is mode-independent — the conditional-append fence is always strong; the mode only trades replica-lag-conflict suppression against RCU.
- New PPX pass [`ReadConsistencyInjection.ml`](../../packages/reventless-ppx/src/ppx/ReadConsistencyInjection.ml) (mirrors `VisibilityInjection`): auto-injects the `EscalateOnRetry` default into StateChangeSlice spec files (folder-detected, plus the `@schema type consumedEvent` + `@schema type event` structural marker that distinguishes a slice from an aggregate/translation slice) and into inline slice specs (test fixtures); a file-level `@@reventless.consistency(AlwaysStrong)` (or `AlwaysEventual`) overrides it; rejected on non-StateChangeSlice files.
- Tests: 3 mode-behaviour cases in `DcbStateChangeSliceTest.res` (438 core tests green) asserting the `readStrongConsistency` sequence for `AlwaysStrong` (`[true]`, `[true,true,true]`) and `AlwaysEventual` (`[false,false,false]`).

**Release coupling (blocker for merge).** Adding a *required* field to `StateChangeSlice.Spec` that only the new PPX injects means every slice spec needs the new binary to compile. CI consumes the **published** `@reventlessdev/reventless-ppx-*` packages (it only builds the PPX from source when the published binary is absent — `ci.yml` `ppx_check`), and `--frozen-lockfile` installs the exact binary the lockfile pins. So this change cannot pass CI until reventless-ppx is **republished at a new version with the lockfile updated**. Verified locally via the dev fallback `ppx-osx.exe` (`pnpm run build:ppx` → `cp src/_build/default/bin/bin.exe ppx-osx.exe`): reventless-spec/core/aws build clean (zero warnings), the catalog example's real slice specs receive the field, and the PPX harness passes (203 cases incl. the new readConsistency injection/override/rejection tests).

**Release sequence (republish-ready as of 2026-06-21):**
1. Version bumped to `1.0.0-alpha.42` in lockstep — `packages/reventless-ppx/package.json` (`version` + both `optionalDependencies`) and all three `npm/{darwin-arm64,darwin-x64,linux-x64}/package.json`.
2. Publish the per-platform binaries (each rebuilt from source → includes the new `.ml`): the `publish-ppx.yml` workflow builds & publishes `darwin-arm64` + `linux-x64`; **`darwin-x64` is published by hand** on an Intel Mac via `pnpm --filter @reventlessdev/reventless-ppx run publish:platform darwin-x64` (out of CI by design).
3. `pnpm install` to repin the lockfile to alpha.42, commit `pnpm-lock.yaml`.
4. Full root build to regenerate every slice `.res.mjs` (the injected `readConsistency` field) + the auth-fix output; commit the regenerated mjs with the source. (Binaries are **not** committed — `.gitignore` excludes `*.exe`.)

**Auth-injection fix folded into the same PPX release — DONE.** The republish would otherwise expose a latent `this match case is unused` warning: `AuthorizationInjection` appended a wildcard `| _ =>` to the `commandAuthorization` switch even for a single-constructor `@authorize` command (e.g. catalog's `ArchiveCategory`). Fixed by tracking the command's total constructor count and omitting the wildcard when the per-constructor rules are **exhaustive** (`rules_are_exhaustive` → `gen_command_authorization_switch ~exhaustive`). Generated output for exhaustive commands is unchanged (ReScript already optimised the switch to a constant return); only the warning is gone. Catalog now builds warning-free.

**Decision (2026-06-21): default eventually-consistent.** Single-tag decision reads stop forcing `consistentRead: true`; they go eventually-consistent by default and rely on the conditional-append fence + retry loop for correctness. This halves decision-read RCU on the common path. Correctness is unchanged in either mode: **DynamoDB conditional writes are always evaluated against the latest committed data**, so a stale read can only ever cause a *rejected* append (then a retry), never a wrong write. Strong reads were never a correctness feature — they only suppress the *replica-lag* class of conflicts, not genuine concurrent-writer conflicts (those serialize at the fence regardless).

**Control surface (decided 2026-06-21: build-time only for now):**
1. **Build-time default** = eventual (slice-spec default; PPX-injected like `authorization`/`visibility`).
2. **Per-slice opt-in to strong** at build time — the static lever for known-hot slices.
3. **Runtime override** (SSM/env, no redeploy) — **deferred** to a follow-up; the general design lives in the new [dcb-high-contention-handling](../analysis/dcb-high-contention-handling.md) analysis (control-surface section), which also evaluates automatic/adaptive adjustment and other contention knobs (sync→async, sharding, escalate-on-retry).

**Threading**: `buildQueryByPartitionKeyInput` / `executeQueryItemStream` / `readStream` already thread `~strongConsistency`; expose it up through `DcbEventLog.operations.readStream` → the slice callback → the slice config. Today the single-tag stream path hardcodes `~strongConsistency=true` ([`DcbEventLogStorage_DynamoDb_Runtime.res` ~L1180](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res)); that becomes the per-slice value (default false).

**Contention metric.** Surface per-slice append-retry and exhausted-retry-conflict rates so the eventual default is observable and hot slices are identifiable. Split by the provider-genericity layering (analysis §7):
- **Core (DONE 2026-06-21): provider-neutral metric signal.** New [`Metrics.res`](../../reventless/reventless-core/src/util/Metrics.res) emits one generic structured JSON line per occurrence (`{reventlessMetric, slice, value, unit}` — **no** `_aws`/EMF/CloudWatch vocabulary; same posture as `Logger`, suppressed outside a JSON sink). Wired into the retry loop ([`StateChangeSlice_Callback.res`](../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res)): `AppendRetry` per retry, `AppendConflict` on a surfaced `Conflict`. Tests: 4 in `MetricsTest.res` (incl. a guard that core emits **no** `_aws`/EMF). *(An earlier draft put EMF in core — reverted; that violated the layering.)*
- **AWS (DONE 2026-06-21): CloudWatch metric filter.** `reventless-aws` translates the generic line into CloudWatch metrics via Pulumi `LogMetricFilter`s on the DCB command-handler Lambda log group. Shipped: (1) new `Cloudwatch_LogMetricFilter` binding in `rescript-pulumi-aws`; (2) a `~dcbMetrics` flag on [`RuntimeEnvironment_Lambda.makeFromCodeAsset`](../../reventless/reventless-aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res), set true only at the DCB command-handler call site ([`PluginRuntime_Builder.res` `forDcbCommandTopic`](../../reventless/reventless-aws/src/plugin/runtime/PluginRuntime_Builder.res)); (3) two filters (`AppendRetry`, `AppendConflict`) in namespace `Reventless/DCB`, extracting `slice` as a dimension + `value`, attached to the **managed** log group (so no race vs Lambda's lazy auto-group). **Constraint**: the managed log group only exists when `logRetentionDays` is set on the command-handler config — without it, no filter is created (the raw signal is still in the logs, queryable via Logs Insights). Namespace/dimension/EMF-vs-filter specifics live entirely in the AWS layer; core stays provider-neutral. Deploy-time wiring — type-checked by the build; not exercised by unit tests (Pulumi resource creation).

**Adaptive auto-tuning is a deliberate NON-GOAL (documented, not an oversight).** A closed loop "conflict rate ↑ → switch to strong" misfires: the conflict population is mostly *genuine concurrent writers* (which strong reads do **not** help — they serialize at the fence), not replica-lag staleness (which strong reads *do* help). Auto-escalating to strong under genuine contention just doubles RCU while conflicts persist. The correct automated response to sustained contention is fence sharding / selective bumping (Issue 10), not strong reads. So: alarm on the metric → human (or a separate, contention-vs-lag-aware policy) chooses the remedy. Runtime override (above) makes that human action fast (no redeploy); full auto-tuning is intentionally out of scope.
- **Issue 5 — composite exact-match guard. — DONE (2026-06-20).** Added `DcbValidation.validateCompositeReads`, run in `Dcb_Builder` against the producer `tagKeysByEventType` map. For each slice that builds a composite read (all-scalar command, ≥2 tags), it warns (`log.warn`, non-fatal) when a consumed type's *produced* tag set is a strict superset of the query tags — the silent-miss case (composite reads match the exact full tag set only). Array commands (per-element OR) are skipped; the strict-subset direction is already handled by Issue 14 narrowing. Tests: 5 in `DcbValidationTest.res` (core suite green at 428); no false positives on the example slices. Was net-new.
- **Issue 4 — per-(tag, event-type) over-serialization.** Document the entity-level serialization semantics; only pursue per-type fences if a real slice suffers (also unblocks Phase 2 option B). Mostly docs.
- **Issue 6 — per-tag `after`.** Note as a deeper design item; each fence checked against the head observed for *its* partition rather than the global head. Defer unless a multi-clause slice shows false conflicts.
- **Issue 9 — `appendUnconditional` bumps all tags.** Align with the partition-scope invariant if/when a composite-fence design (option A) lands; today it is seeding-only and benign.
- **Issue 12 — tagless scan + fence items. — DONE (2026-06-20).** The tagless, type-less read path is reachable (no current slice exercises it — DCB commands always carry the entity id as a tag — but the path exists). Hardened defensively: extracted a pure `buildScanFilter` (shared by `scanWithFilter`/`scanWithFilterStream`) that always asserts `attribute_exists(event)`, so `fence#…` sentinels are never returned, and fixed the degenerate empty-`eventTypes` `()` filter. Tests: 3 in `DcbEventLogStorage_DynamoDb_RuntimeTest.res` (AWS suite green at 126).
- **Issue 14 — drop vacuous query-clause type combinations. — DONE (2026-06-20).** `buildQueryFromCommand` now takes an optional `~tagKeysByEventType` map (event type → produced tag-key set), threaded from `Dcb_Builder` (which knows every producer's `eventSchema`) through `StateChangeSlice.make` → `_Callback`. Each clause keeps a consumed type only if that type's **full produced tag set** carries the clause's tag(s) (`narrowEventTypesForTags`); the map is built via `DcbTag.extractTagKeysByEventType` + `mergeTagKeysByEventType` from the *producer* schemas, never a consumer's `consumedEventSchema`. Pure dead-clause removal — vacuous clauses match nothing, so results unchanged; a type carrying the tag as a *secondary* (e.g. `OrderPlaced` under `productId`) is **retained** (legitimate cross-partition read = Phase 7 / Issue 13). Tests: 4 in `DcbTagTest.res` (core suite green at 423; local + example builds green). Was net-new.
  - **Docs follow-up — DONE.** Updated the published [internals/dcb-consistency-checks](../../packages/doc/docs-framework/internals/dcb-consistency-checks.md) Stage 1 `PlaceOrder` example: the `orderId` clause now lists only `OrderPlaced`; the `productId` clauses keep both types; added the note that clauses list only types whose produced tag set carries the clause's tag.

## Phase 6 — Profile-gated throughput & cleanup

Already planned, run on evidence:
- [dcb-hot-tag-fence-contention](Backlog/dcb-hot-tag-fence-contention.md) — selective bumping (§2, cost-saver, can ship early) then sharding (§1, profile-gated). **Profiling evidence landed 2026-07-07**: a downstream deploy-time sync workload bursts per-entity appends that all share the same low-cardinality scope tags → those fences go hot → `retries exhausted: TransactionConflict` at the command bus (observed live). First real workload for §2/§3; see the plan's "Triggering evidence" section.
- [dcb-monotonic-position-generation](Backlog/dcb-monotonic-position-generation.md) — half-day cleanup, land any time someone is in `Runtime.res`.

## Phase 7 — Cross-partition secondary-tag reads (capability) — **IMPLEMENTED (2026-06-21, source; mjs/CI pending ppx republish)**

Shipped per [dcb-phase7-cross-partition-reads](done/dcb-phase7-cross-partition-reads.md) § "What shipped": the `@crossPartition` schema annotation + PPX pass (Part 1), query fan-out + `tag_<key>` GSI read routing (`Query` keys → `GetItem` payloads, Part 2), and cross-partition fence scope (check+bump by every carrier, Part 3), threaded from `Dcb_Builder` (`extractCrossPartitionTagKeys` + `validateCrossPartitionScope`) through the storage maker and the slice callback. Validated via a synthetic course-subscription fixture across `DcbTagTest` / `DcbValidationTest` / the AWS runtime fence test / the PPX harness (all green); no table change (reuses the Phase 3 `KEYS_ONLY` GSIs). Like `readConsistency`, the `.res.mjs` regenerate at the shared reventless-ppx republish. The reference material below is retained for context.

**Goal**: support reading a single tag *across* partitions — i.e. reading an event type by a tag it carries as a *secondary* (non-partition) tag. Today a single-tag read is partition-scoped, so this is impossible; it's the canonical DCB shape for any M:N decision (course-subscription capacity, "≤ N orders per product", reservations). Full motivation, worked example, solution sketch, and cost analysis: [analysis Issue 13](../analysis/dcb-consistency-check-issues.md#issue-13--no-single-tag-cross-partition-secondary-tag-read-capability-gap).

**Why it's its own (deferred) phase, and how it couples to Phase 3.** The clean realisation **re-uses the per-tag `tag_<key>` GSI that Phase 3 down-projects to `KEYS_ONLY`** — so when Phase 7 lands, the cross-partition read path is a `Query → BatchGetItem` against keys-only, not a single `Query` against `ALL`. The extra round-trip is the price paid for keeping the per-write WCU + storage cost down while Phase 7 is still evidence-gated; bounded reads (`Limit:N+1`) and the Phase 4 cache keep that cost manageable in practice.

**Shape of the work** (three coupled parts, from the analysis):
1. **Per-tag scope flag** (a dedicated `@crossPartition` field annotation mirroring `@partitionTag`; default `PartitionScoped` for un-annotated tags) — the single control surface; also resolves the Issue 14 residual (it's what tells the builder a secondary-tag clause is *wanted*, not just tolerated).
2. **Read routing** — a `CrossPartition` single-tag clause reads the per-tag GSI instead of the base-table partition.
3. **Fence scope follows read scope** — a `CrossPartition` tag is fence-bumped by *every* carrier (not just events partitioned by it), or OCC misses concurrent secondary-tag writers; partition-scoped tags keep the narrow rule.

**Cost note**: read-dominated and paid on *both* tags of an M:N event (O(entity degree), eventually-consistent, uncached). Highest-leverage mitigations are framework-level — `Limit:N+1` count-bounded reads for capacity invariants and the Phase 4 decision-model cache — not infra. See analysis Issue 13 § Performance & cost.

**When to do it**: profile-/evidence-gated — only when a real slice needs a cross-partition read. Until then it stays a future capability, and slices that merely *tolerate* over-reads (e.g. `PlaceOrder`) handle it in their behaviour.

## Suggested execution order

1. ~~**Phase 1** (verification harness + Phase 0 regression cases)~~ — **done 2026-06-20**.
2. ~~**Phase 2** (create-race close)~~ — **done 2026-06-20**. 2A confirmed the hole is real on the default sync path; shipped option B (per-type create guard).
3. ~~**Phase 3** (down-project per-tag GSIs to `KEYS_ONLY`) — biggest durable $ win, no contract change.~~ — **done 2026-06-21** (preserves Phase 7 optionality; needs an alpha DcbEventLog table wipe on next deploy).
4. ~~**Phase 4** (decision-model cache) — biggest read-cost win.~~ — **core done 2026-06-20** (Steps 1–3 + docs); per-slice capacity knob + metrics deferred.
5. **Phase 5** items opportunistically — Issue 14 (vacuous-clause cleanup), Issue 12 (fence-scan hardening), Issue 5 (composite exact-match guard) **done (2026-06-20)**, and Phase 5a (opt-in strong reads + contention metric) **done (2026-06-21)**, including the per-slice strong-read override PPX follow-up **implemented (2026-06-21, pending a reventless-ppx republish to merge)**; remaining items (Issues 4/6/9) land opportunistically. **Phase 6** on profiling evidence.
6. **Phase 7** (cross-partition reads) — only when a real slice needs it; reuses the per-tag `KEYS_ONLY` GSI Phase 3 leaves in place (`Query` → `BatchGetItem`).
