# Plan: Minimize the Lambda EntryPoint `.mjs` Shell — Typed ReScript Core

**Status**: Prototype landed (DcbCommandTopic typed core compiles). Rollout not started.

**Related history**:
- [migrate-bundling-js-to-rescript.md](done/migrate-bundling-js-to-rescript.md) — moved deploy to compiled ReScript entry points (Alternative D).
- [migrate-entrypoints-to-mjs.md](done/migrate-entrypoints-to-mjs.md) — reversed the above: the `.res` entry points were "ReScript in name only" (`'a => 'b`, `%raw`, `Obj.magic`), gave no real type safety, and hid a prod bug. Rewrote all 14 to hand-maintained `.mjs`.

This plan is **not** a reversal of the reversal. The `.mjs` rewrite was right about the boundary it fled — the dynamic `import()` of user modules and the compile-time functor invocation genuinely resist ReScript. It was wrong to also push the *typed framework-call logic* into untyped `.mjs`, where invariants survive only as comments. Two of those comment-guarded invariants have already shipped as production incidents.

## Rationale

The entry-point `.mjs` files have grown from cold-start glue into real logic — scope derivation, partition-tag derivation, storage-ops wiring, routing — that calls **typed** framework functions with **untyped positional args**. The callee is compiler-checked; the call site is not. That gap has cost us:

- **[dcb-runtime-scope-annotation-drift](../analysis/dcb-runtime-scope-annotation-drift.md)** — the DCB entry point re-derived decision-read scope from annotations alone, silently dropping inferred cross-partition reads → every reference-guarded command rejected in prod.
- **[dcb-composite-fence-residual-burst-contention](done/dcb-composite-fence-residual-burst-contention.md)** — the entry point dropped `partitionTag` when threading storage ops → composite fence collapse never fired → TransactionConflict bursts in prod.

Both are compiler-enforceable invariants that a typed call site would have caught at build time. `DcbCommandTopicEntryPoint.mjs` alone carries **4 "positional args match the compiled signature" comments** standing in for that lost enforcement.

## The pattern: typed core + minimum shell

Split each substantive entry point into two files:

**`<Name>EntryPoint.mjs` — the minimum shell.** Owns *only* the boundaries that are inherently untyped or compile-time-only:
1. Read `HANDLER_CONFIG` / env vars.
2. Dynamically `import()` user Spec/Behavior modules (types unknowable at cold start).
3. Invoke the compiled functor(s) (`StateChangeSlice_Callback.Make(spec)(behavior)`, etc.) — ReScript functors can't take runtime module values, so this stays a typed `external` boundary in the core, called here.
4. The Lambda `handler(event, context)` signature + `Effect.runPromise` wrapper + request-id/log annotation.

**`<Name>EntryPoint_Ops.res` — the typed core.** Everything else, compiler-checked against the real framework signatures: config decode, all derivations, storage-ops construction (labeled args), routing-map keys, outcome shaping. The one sanctioned coercion is an opaque `specModule` type with typed field getters (`@get external`), replacing the old scatter of `Obj.magic`.

**Boundary rule (the test for "does this line belong in the shell?"):** a line stays in `.mjs` only if it (a) touches `process.env`/`HANDLER_CONFIG` raw JSON, (b) performs a dynamic `import()`, (c) invokes a functor with a runtime-loaded module, or (d) is the AWS handler entry signature. Everything else moves to `_Ops.res`.

## Prototype (done)

[DcbCommandTopicEntryPoint_Ops.res](../../reventless/reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint_Ops.res) — exposes `deriveScope`, `makeDynamoStorageOps(~tableName, scope)`, `commandTypeNames`. Compiles clean under warnings-as-errors (`-44+101`). The compiled `append(table, partitionTag, crossPartitionTagKeys)` is byte-identical to the hand-written `.mjs` call — but now generated from a compiler-verified labeled call. Both prod-incident derivations are now typed. Shell delta: ~90 untyped lines (original ~98–191) collapse to ~5. Not yet wired into the live shell.

## Per-file triage (revised after implementation)

**Key finding:** the initial triage ranked by line count + res-call count. Implementation showed those overstate payoff. The real driver is narrower: **positional calls into compiled storage/derivation signatures** — the drift class that caused the two prod incidents. A file only earns a typed core if it *selects and assembles* backend storage/query ops or *derives* framework scope from schemas. Everything else — functor invocation over dynamically-imported modules, AWS SDK orchestration (AppSync schema push, SNS subscriptions, CloudWatch schedules, S3/stream channel handlers) — is the sanctioned shell boundary and gains nothing from ReScript (it would just reintroduce untyped `external` surface). The `sig-comments` scan column turned out to be the honest predictor: only files with the positional-into-compiled smell were worth splitting.

| File | lines | Verdict | Why |
|---|---|---|---|
| `DcbCommandTopicEntryPoint` | 326→262 | **Split ✓** | scope + partitionTag derivation, Dynamo/Postgres storage-ops selection (2 prod incidents) |
| `AggregateEntryPoint` | 331→319 | **Split ✓** | EventLog storage-ops selection; also restored dropped snapshot ops |
| `ReadModelEntryPoint` | 172→170 | **Split ✓** | DynamoDB QueryDb ops assembly (shared `QueryDbEntryPoint_Ops`) |
| `StateViewSliceEntryPoint` | 169→163 | **Split ✓** | same QueryDb ops assembly (shared core) |
| `AdminEventCollectorEntryPoint` | 879 | **Leave `.mjs`** | functor wiring over runtime modules + AWS orchestration (SNS subs, AppSync schema push, CW schedules); `sig-comments=0` — no storage-ops selection or derivation to type |
| `PgQueryResolverEntryPoint` | 88 | **Leave `.mjs`** | Postgres-only; `pgQdbOpsFor`/`deriveServerCapability` are single typed calls, no Dynamo/pg *selection* to type |
| `PluginExtensionPointEntryPoint` | 137 | **Leave `.mjs`** | functor wiring (`extensionPointCallbackMake`, `commandTopicCallbackMake`) over runtime modules |
| `AutomationSliceEntryPoint` | 124 | **Leave `.mjs`** | functor + DynamoDB-stream channel glue; no storage-ops selection |
| `TaskBucketEntryPoint` | 150 | **Leave `.mjs`** | S3 bucket-event channel glue + `sqsPublishJsons` |
| `ExtensionPointEntryPoint` | 101 | **Leave `.mjs`** | functor wiring over runtime modules |
| `EventMapperEntryPoint` | 97 | **Leave `.mjs`** | functor wiring (`MakeCounterHandler`/`MakeEventCollectorHandler`) |
| `CounterEntryPoint` | 91 | **Leave `.mjs`** | functor wiring + `qdbCount` (single typed call) |
| `SideEffectEntryPoint` | 81 | **Leave `.mjs`** | functor wiring + stream channel glue |
| `PgChangeFeedRelayEntryPoint` | 57 | **Leave `.mjs`** | thin glue |
| `PgMigrationEntryPoint` | 40 | **Leave `.mjs`** | thin glue |
| `HeartbeatEntryPoint` | 38 | **Leave `.mjs`** | thin glue |

Net: **4 files split** (the ones with genuine storage/derivation drift), **12 left as `.mjs`** (legitimate shell code). The remaining "positional args match compiled signature" comments in the two command-path shells (`handleCommands`, `makeGenerateCommand`) sit at the functor / runtime-loaded-schema boundary — they can't be typed away without the runtime module's type, so they stay as *documented* boundaries, not unaddressed smells.

## Phases

- [x] **Phase 1 — DcbCommandTopic (finish the prototype).** Wire the live `DcbCommandTopicEntryPoint.mjs` to the typed core; add the Postgres branch (`makePostgresStorageOps` in `_Ops`, typed `PgConnection.connectionConfig` decode). Run the DCB command-topic integration test (drives `buildHandlersForConfig` against DynamoDB Local). Confirm the shell is minimum per the boundary rule. **Done:** `DcbCommandTopicEntryPoint_Ops.res` (deriveScope / commandTypeNames / makeStorageOps, Dynamo + Postgres branches) compiles clean under `-44+101`; shell trimmed 326→262 lines; `DcbCommandTopicEntryPoint_IntegrationTest` green (3 tests).
- [x] **Phase 2 — Aggregate.** Same split. Highest command-path traffic; do it early and watch it on the next deploy. **Done:** `AggregateEntryPoint_Ops.res` exposes `makeStorageOps(~tableName, ~pgConnection)` (Dynamo + Postgres), compiles clean. Shell trimmed 331→319; the storage-ops selection moved to the core, functor wiring stays in the shell (consumes runtime-loaded modules). **Behavioral note (surfaced, not hidden):** the core returns the full 6-field `EventLog_Adapter.operations`; the old shell dropped `latestSnapshot`/`writeSnapshot` on both backends, so the Lambda now matches the deploy-time adapter — no-op when snapshotting is off, a fix when on. No dedicated Aggregate entry-point integration test exists; gated by the compiler + CI `online-shop-hybrid` deploy smoke.
- [x] **Phase 3 — AdminEventCollector.** **Reclassified to Leave `.mjs`.** Close reading of `buildHandler` showed the 879 lines are functor wiring over dynamically-imported modules + AWS SDK orchestration (SNS subscription reconciliation, AppSync schema push with shrink guards, CloudWatch schedules) — the sanctioned shell boundary. `sig-comments=0`: no storage-ops selection or schema derivation to type. A ReScript rewrite here would move AWS SDK glue behind untyped externals — the exact failure mode of the previous reversal. No change made.
- [x] **Phase 4 — ReadModel, StateViewSlice.** **Done:** shared `QueryDbEntryPoint_Ops.res` exposes `makeDynamoQueryDbOps(~tableName)` returning the full 7-field `QueryDb_Adapter.operations`. Both shells' DynamoDB branches now call it; the Postgres branch (`pgQdbOpsFor` + env-gated `withLiveUpdates`) and id-injection wrappers stay in the shell. `StateViewSliceEntryPoint_IntegrationTest` green; ReadModel shares the identical core.
- [x] **Phase 5 — Mid-tier.** **Reclassified to Leave `.mjs`.** PgQueryResolver, PluginExtensionPoint, AutomationSlice, ExtensionPoint, EventMapper, Counter, TaskBucket, SideEffect are all functor-over-runtime-modules + AWS channel glue (S3/DynamoDB-stream/SQS handlers), with at most single typed calls (`qdbCount`, `pgQdbOpsFor`, `deriveServerCapability`) and no storage-ops *selection* to type. No change made.
- [x] **Phase 6 — Sweep.** Grepped remaining shells for "positional args match the compiled signature": survivors are `handleCommands` (functor output) and `makeGenerateCommand` (runtime-loaded `commandSchema`) in the two command-path shells — both at the functor / runtime-module boundary, un-typeable without the loaded module's type. Left as documented boundaries. Full `reventless-aws` build clean under `-44+101` (zero warnings); DCB + StateViewSlice + DcbEventLog integration suites green (18/18).

## Testing / verification

- Each `_Ops.res` compiles under warnings-as-errors — a signature drift in the framework becomes a build failure (the whole point).
- Per entry point, the existing integration test (where one exists) must stay green; where a shell has no test, add one that drives the core against DynamoDB Local / in-memory before splitting.
- The compiled `_Ops.res.mjs` for each storage/derivation call must be diff-checked against the current hand-written `.mjs` call once, to confirm behavioural identity (positional order, optional-arg handling). The DcbCommandTopic diff already matched.
- Deploy verification: the reversal plan's outstanding item ("confirm all Lambda types run in CloudWatch") applies here too — smoke each split Lambda type on the CI deploy of `online-shop-hybrid`.

## Follow-up tiers (deeper typing beyond storage/derivation)

After the four storage/derivation splits, two further tranches were evaluated against the "does typing catch real drift, and can I verify it?" bar.

- [x] **Tier 2 — `makeCommandGenerator` wrapper.** Shared `CommandGeneratorEntryPoint_Ops.res` wraps `CommandGenerator_Callback.makeGenerateCommand` with the arg order, the `commandComponentKind` variant, and a *required* `stripIdFromParams` all compiler-checked — closing the documented "omitting the trailing arg shifts everything left" trap in both command-path shells. Wired into Aggregate + DCB; DCB integration test (drives `cmdGenHandler` → the wrapper) green.
- [x] **Tier 2.5 — DCB slice-handler wiring.** `buildSliceHandler` in `DcbCommandTopicEntryPoint_Ops.res` now owns the `StateChangeSlice_Callback.Make` functor call, the JSON→command decode, and the **positional `handleCommands` invocation** (the line-146 sig-comment / 2026-06-21 arity-drift incident). Loaded Spec/Behavior enter opaque (clean functor pass-through — not field-poked); `dcbEventLog` enters boundary-typed. DCB shell 326→240 lines cumulatively. Integration-tested green (drives the full `cmdGenHandler` → composite → `buildSliceHandler` → `handleCommands` path).
- [ ] **Tier 2.5 — Aggregate functor wiring. Declined, with reason.** Unlike DCB, Aggregate's functor configs (`eventLogOperationsMake({Spec, EventTopic, eventTopic, storage})`, `aggregateCallbackMake(...)({Spec, EventLog, eventLog})`) are **named-field records dominated by opaque first-class-module fields** — there is no positional-order drift to catch (its only sig-comment was `makeGenerateCommand`, closed by Tier 2), so typing them checks little beyond the already-typed `storage`. Decisively: **there is no Aggregate entry-point integration test.** Reconstructing opaque-config functor wiring in ReScript would *compile* but couldn't be verified short of a deploy — the "compiles but silently wrong" trap on a critical command path. Not prudent without first adding an Aggregate integration harness (a separate task).

**Net after all tiers:** every positional-into-compiled-signature call in the shells is either eliminated or moved behind a typed core. The only remaining framework calls in shells are named-field functor configs over opaque runtime modules — where ReScript would add ceremony, not safety.

## What stays in `.mjs` (non-goals)

- The dynamic `import()` seam and the functor invocation — always. Do **not** reintroduce typed-`external`-everything `.res` entry points; that is the exact failure mode of the previous reversal.
- Thin-glue files under ~60 lines with no dynamic import (Heartbeat, PgMigration, PgChangeFeedRelay).
- Effect/Stream routing glue may stay in the shell where lifting it buys no invariant enforcement; move it only when it clarifies the shell/core boundary.

## Rollback

Each split is per-file and additive (`_Ops.res` is new; the shell edit is a mechanical delegation). Revert a single file's shell edit + delete its `_Ops.res` to return to the current hand-written `.mjs`. No cross-file coupling between phases.
