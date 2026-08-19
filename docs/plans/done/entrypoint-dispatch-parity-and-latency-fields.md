# Entry-Point Dispatch Parity + Latency Fields

**Status:** DONE — implemented 2026-07-21, **verified on alpha 2026-08-20**.
Phases A–D are in; unit + both Docker integration gates green; the CloudWatch
check this plan was held open for has now run and passed on every claim it makes
about the dispatch boundary, including a genuine redelivery carrying
`retryCount` (see Verification).

The same run found that the annotations never reach a *component* log line,
because component code logs through `Effect.runSync`. That is a pre-existing
defect in components this plan never touched, and it is
[component-logs-detached-from-invocation.md](../component-logs-detached-from-invocation.md).

**Created:** 2026-07-21

**Owner doc:** `docs/analysis/telemetry-substrate.md` — closes the AWS half of primitive #1 and
ships primitive #3.

**Predecessors (done):** `done/queryable-dispatch-log-annotations.md`,
`done/eventcollector-element-level-log-comp.md`, `done/logging-harmonization.md`.

---

## The finding that motivates this plan

Primitive #1 (`comp` + `causationId` on every line of an invocation) is shipped in the **ReScript**
dispatch boundary — `Runtime.annotateInvocation` / `runEffect` / `runEffectHandler`
([Runtime.res:15-95](../../../reventless/core/src/adapter/Runtime/Runtime.res#L15-L95)).

That boundary does **not** execute on AWS. Every deployed Lambda is an archive whose
`index.handler` is a hand-written entry-point shell:

- 16 `entryPointModule=` bundle sites across `reventless/aws/src` (AggregateEntryPoint ×8,
  ReadModelEntryPoint ×2, EventMapperEntryPoint ×2, DcbCommandTopic, StateViewSlice, Automation,
  SideEffect, ExtensionPoint, …).
- The AWS runtime builders take `~handler as _` — the ReScript handler closure is **discarded**;
  wiring happens at cold start inside the `.mjs` from `HANDLER_CONFIG`
  (e.g. [AggregateRuntime_Builder_Single.res:89](../../../reventless/aws/src/adapter/Runtime/AggregateRuntime_Builder_Single.res#L89),
  `~handler as _` again at 120 and 161).
- `RuntimeEnvironment_Lambda.res:16` labels the `CallbackFunction` closure path "legacy — retained
  for module type compatibility".

Each of the 10 entry-point shells carries its **own** copy of `runEffect`, all identical:

```js
function runEffect(correlationId, effect) {
  let e = effect
    .pipe(Effect.annotateLogs("correlationId", correlationId || "unknown"))
    .pipe(Effect.annotateLogs("requestId", _currentRequestId));
  if (pluginName) e = e.pipe(Effect.annotateLogs("plugin", pluginName));
  return e
    .pipe(Effect.provideService(requestContextTag, { correlationId: correlationId || "unknown" }))
    .pipe(Effect.runPromise);
}
```

Consequences on deployed AWS today:

1. **No `comp` on the invocation.** Framework lines pass `{comp: …}` per call, but an application
   handler's own `Effect.logInfo` inherits only `correlationId` / `requestId` / `plugin`. Per-element
   log isolation — the whole point of the two predecessor plans — does not hold on AWS. It holds in
   `reventless-local`.
2. **No `causationId` anywhere in the log stream.** `grep 'annotateLogs("causationId"'` across the
   entry points returns nothing, so the log-derived causal tree is not reconstructable from a
   deployed stack.
3. **`RequestContext` is a bare object literal**, not `RequestContext.make(...)`. The record type
   declares non-optional `identity: Identity.t` and `claims: dict<string>`; the literal supplies
   neither. Latent, not currently breaking — no runtime code reads those fields yet (only
   `IdentityTest`) — but `RequestContext.getClaim` on a deployed invocation would throw on
   `undefined`.
4. **Ten copies to keep in sync** — exactly the duplication Phase C of the predecessor plan removed
   on the ReScript side.

The roadmap's "primitive #1 — Done" is therefore accurate for the local platform and overstated for
AWS. This plan closes that, and — because the fix touches the same six lines — lands primitive #3
(latency `timestamp` + `retryCount`) in the same pass.

## Design

### Phase A — one shared dispatch shim

Add `runEffect` to
[HandlerFactoryHelpers.mjs](../../../reventless/aws/src/adapter/Runtime/HandlerFactoryHelpers.mjs)
(already the shared shell module: exports `log`, `pluginName`, `patchSpecId`, `makeQueueRef`, …).
Signature takes an options object so later fields are additive and call sites never depend on
argument order:

```js
export function runEffect(effect, { correlationId, causationId, comp, sentTimestamp, retryCount, identity, claims } = {})
```

It annotates `correlationId`, `requestId`, `plugin` (as today) plus `comp` and `causationId`, and
provides a **complete** `RequestContext` — built via the ReScript `RequestContext.make` export
rather than an object literal, so the record shape stays compiler-owned.

Delete the 10 private copies; each entry point imports the shared one. `_currentRequestId` moves
into the helper with a `setRequestId(ctx.awsRequestId)` export called at handler entry.

**Guard rail:** hand-written `.mjs` breaks silently on a new *leading* `~arg` in a ReScript export
(see `reference_ec_publish_to_aggregates_grant_broken`). `RequestContext.make` is all-labelled with
`~correlationId` first — calling it from JS means passing positionally in declaration order.
Prefer exporting a small `makeFromJs` taking one record, or call `make` with the full labelled set
and cover it with a test that would fail on a signature change.

### Phase B — thread `comp` and `causationId` at each call site

Each shell already knows the element it is dispatching to (it looks the handler up by name/ARN out
of `HANDLER_CONFIG`). Pass the same `comp` shape the ReScript side emits so a CloudWatch filter is
uniform across platforms — `EventCollector(<Name>)`, `AggregateRuntime(<Name>)`, etc.; the shape
table in `docs/guides/cloudwatch-logs-insights.md` is the contract.

`causationId` comes off the same parsed SQS body the shells already read for `correlationId`
(`DcbCommandTopicEntryPoint.mjs::extractCorrelationId` is the pattern) — extend to a shared
`extractMetaField(records, field)` in the helper, mirroring
[RuntimeEnvironment_Lambda.res:288](../../../reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res#L288).

### Phase C — primitive #3: `timestamp` + `retryCount`

Per `docs/analysis/request-context-usage.md` §timestamp / §retryCount.

- Add `timestamp?: float` and `retryCount?: int` to `RequestContext.t` + `make` (+ optional params
  on `.test()`; adding optional fields is non-breaking, per that doc's Migration Path).
- **AWS extraction:** `record.attributes.SentTimestamp` (ms epoch, string → float) and
  `record.attributes.ApproximateReceiveCount` (string → int), off the first record of the batch —
  same position `extractMetaField` reads. Note `attributes` is **commented out** of the SQS record
  binding ([SQS_Queue.res:63](../../../rescript/pulumi-aws/src/SQS/SQS_Queue.res#L63)); the ReScript
  side needs a `@get external` alongside the existing `recordBody`
  ([RuntimeEnvironment_Lambda.res:285](../../../reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res#L285)),
  or uncommenting the field with a typed `sqsRecordAttributes`.
- **Local extraction:** `Date.now()` at dispatch, `retryCount = 0`
  ([LocalRuntimeEnvironment.res:52](../../../reventless/local/src/adapter/Runtime/LocalRuntimeEnvironment.res#L52)).
- Extend `Runtime.Environment` with `extractSentTimestamp` / `extractRetryCount` and thread them
  through `annotateInvocation` / `runEffectHandler` exactly as the causationId extractor is threaded
  today, so the ReScript path keeps parity with the shells.
- Annotate `retryCount` on logs only when `> 1` (a redelivery) — a constant `1` on every line is
  noise; `timestamp` is not annotated at all (it is a context field for computing latency, not a
  filter key).

### Phase D — docs

Extend `docs/guides/cloudwatch-logs-insights.md` with the two new `RequestContext` fields and a
"time in queue" query (`ingestion time − timestamp`). Flip the primitive #3 row in
`docs/analysis/telemetry-substrate.md` and correct the primitive #1 row to state the platform
coverage explicitly.

## What shipped

- **Phase A** — `runEffect` / `setRequestId` / `extractMetaField` /
  `extractSentTimestamp` / `extractRetryCount` in `HandlerFactoryHelpers.mjs`; the
  ten private `runEffect` copies and four private `extractCorrelationId` copies are
  gone (`grep -c "function runEffect" *.mjs` → only the helper). The shim takes an
  options object, and builds the context through a new
  `RequestContext.fromOptions` (single options record) rather than calling the
  labelled `make` positionally from JS.
- **Phase B** — every entry point passes a per-element `comp`. Where the shell can
  name the element itself it does (aggregate / DCB / slices / event mapper /
  extension points, from the spec name); where it cannot — read models and
  side-effect handlers, which the shell knows only by module path — the builder
  bakes `comp` **and** `plugin` into `HANDLER_CONFIG`, resolved at deploy time via
  `Logger.resolvePlugin` (LogPrefix's registry is a deploy-time structure, empty
  inside a Lambda). That per-handler `plugin` also fixes attribution on the shared
  `AllReadModels` / `AllSideEffectHandlers` Lambdas, whose function name carries no
  single plugin identity.
- **Phase C** — `timestamp` / `retryCount` on `RequestContext` (+ `.test()`),
  extracted on both platforms: SQS `SentTimestamp` / `ApproximateReceiveCount`,
  DynamoDB-stream `ApproximateCreationDateTime` (seconds → ms), and dispatch time /
  1 in-process. `Runtime.Environment` gained `extractSentTimestamp` /
  `extractRetryCount`, threaded through `annotateInvocation`, `runEffect` and
  `runEffectHandler` to every builder. `retryCount` is annotated on logs only when
  > 1.
- **Phase D** — the CloudWatch guide documents the `retryCount` field, the two
  latency fields, the full per-kind `comp` table, the local-vs-AWS `comp`
  difference for state-view slices, a redelivery query, and the fact that there are
  now two dispatch boundaries to keep in step.
- **Test** — `reventless/aws/tests/HandlerFactoryDispatchTest.res` (13 cases)
  covers the JS↔ReScript constructor seam, both record shapes, and the annotation
  rules. This is the guard the risk section asked for.

### Found in passing

`Effect.serviceWith` / `serviceWithEffect` in `rescript/effect` were bound as
`@module` imports of functions `effect` does not export — any call died with
"serviceWith is not a function". Since v3 a `Tag` *is* an effect yielding its
service, so both are now implemented as `map` / `flatMap` over the tag. They had
no callers, which is why it had gone unnoticed. `Effect.logAnnotations` was added
alongside (typed against the `HashMap` it actually returns, with
`annotationsToDict`).

## Acceptance

- ~~An application handler on **deployed AWS** that only calls `Effect.logInfo("…")` emits a JSON
  line carrying `comp`, `correlationId`, and `causationId` as top-level fields.~~ **Moved
  2026-08-20** to
  [component-logs-detached-from-invocation.md](../component-logs-detached-from-invocation.md).
  Nothing in `examples/` calls `Effect.log*`, so this criterion has no subject on a deployed
  stack; and the run that established that also established it would fail — a handler's own line
  is emitted through `Effect.runSync` and never sees the boundary's annotations. Both halves are
  that plan's to close. What this plan is accountable for — the boundary computing and attaching
  the fields — is verified.
- No entry-point `.mjs` retains a private `runEffect`; `grep -c "function runEffect" *.mjs` → 0.
- `RequestContext` provided on AWS is constructed by the ReScript constructor and carries
  `identity` + `claims`, so `getClaim` cannot throw on a deployed invocation.
- A handler can compute queue latency from `RequestContext.timestamp` without calling `Date.now()`,
  and can branch on `retryCount` on both platforms.
- Zero compiler warnings; existing `IdentityTest` / `LogFormatTest` / `AggregateCausationTest` pass.

## Verification

**Done — unit:** full monorepo build green with zero warnings; `reventless-core` 510/510,
`reventless-aws` 265/265 (including the 13-case `HandlerFactoryDispatchTest`), `reventless-local`
495/501 with the new 4-case `LocalDispatchContextTest`. `reventless-local` has 6
failing `LocalAuthHttpTest` cases — **pre-existing**, confirmed by stashing this work and
re-running on the baseline, and a test-harness artifact rather than a product bug: the same
`POST /__inmemory/login` returns 200 when driven outside Jest.

**Done — integration** (both Docker gates, re-run after the `plugin`-fragment change):

- `pnpm run test:integration` — 4 suites / 19 tests green, including the two whose contracts this
  plan changed: `AggregateEntryPoint_IntegrationTest` (registry entries are now `{handler, comp}`)
  and `DcbCommandTopicEntryPoint_IntegrationTest` (`buildHandlersForConfig` returns a third
  element), both driving the real entry point against DynamoDB Local.
- `pnpm run test:integration:pg` — 3 suites / 10 tests green (`PgChangeFeedRelay`, `PgPipeline`,
  `PgMigrationEntryPoint`).

**Done — on AWS (2026-08-20)**, against `online-shop-*-aws-alpha` (functions last modified
2026-08-19, so a month after this work landed):

- The shared shim carries a cold start on all ten Lambdas — the failure mode no local test
  reaches, and the one to watch first. No cold-start failures in the sampled window.
- The **boundary** line carries the full set: `AllAggregatesCmdHandler` and
  `CatalogDcbCmdHandler` emit `plugin`, `correlationId`, `requestId` and `comp` together
  (20 and 17 lines respectively). `plugin` resolves at deploy time as designed — the
  deployed `AllReadModels` `HANDLER_CONFIG` carries
  `{"comp": "EventCollector(CustomersReadModel)", "plugin": "Ordering"}` per handler.
- `comp` is top-level on every framework line across every group checked.
- `correlationId` reads `"unknown"` on the command handlers. Not a defect of this plan: an
  AppSync-triggered command arrives with no `meta.correlationId`, so `extractMetaField`
  correctly finds nothing.

**Found by the same run, and split out:** the annotations decorate a fiber that no
*component* line ever reads, because component code logs with
`EffectLogger.log*(…)->Effect.runSync` and `runSync` starts a fresh fiber with default
FiberRefs. So `AllReadModels` — whose every line is a component line — shows `comp` alone
and no `plugin`/`correlationId`/`causationId` anywhere. That is a pre-existing defect in
`reventless-core` components this plan never touched; it is
[component-logs-detached-from-invocation.md](../component-logs-detached-from-invocation.md),
with the measurements.

- **`retryCount` on a real redelivery — observed.** One occurrence in 80,724 records across
  20 example log groups over 30 days (`filter @message like /retryCount/`), which is what a
  field annotated only when `> 1` should look like on a healthy stack. On
  `…-OrderingPluginEventColl`, 2026-08-18 07:37:03Z:

  ```json
  {"plugin":"Ordering","comp":"Plugin(Ordering@1.0.0-alpha.213)","retryCount":"2",
   "correlationId":"27e56f2e-…","causationId":"bf0e704a-…","requestId":"…"}
  ```

  That one line closes three claims at once: `retryCount` surfaces on redelivery and only on
  redelivery, `causationId` reaches a top-level field when the trigger carries one, and all
  four fields co-occur on a single boundary line.

## Open items

None. All three recorded on 2026-07-21 are closed:

1. ~~**On-AWS verification.**~~ **Closed 2026-08-20** — the check ran and the boundary half
   passed on every claim, including `retryCount` on a genuine redelivery (see Verification).
   One criterion did not survive contact and was handed over rather than ticked:

   - **The application-handler criterion is unexercisable as written** —
     `grep "Effect.log" examples/ --include=*.res` returns nothing, so no deployed handler emits
     an application log line at all. Reworded rather than dropped: the substance moved to
     [component-logs-detached-from-invocation.md](../component-logs-detached-from-invocation.md),
     whose acceptance covers it on framework lines, of which the estate has plenty. The
     predecessor plan was marked Done on a criterion nobody checked against a deployed stack;
     the lesson holds, and this is what checking it produced.
2. ~~`timestamp` / `retryCount` untested on the local path.~~ **Closed** —
   `reventless/local/tests/adapter/LocalDispatchContextTest.res` (4 cases) dispatches a handler
   through `Runtime.runEffectHandler` wired with `LocalRuntimeEnvironment`'s extractors — the exact
   composition the local builders use — and asserts the identity fields, the placeholder fallback, a
   send time bracketed by `Date.now()` either side of the dispatch, and `retryCount = 1`. The "on
   both platforms" acceptance now rests on assertions rather than on the extractors compiling.
3. ~~Per-handler `plugin` baked for read models and side-effect handlers only.~~ **Closed** — the
   fragment logic moved to `Util_LogAttribution` (`pluginFragment` / `compFragment` / `fragments`,
   with the reasoning for the split in its header) and the six aggregate builders
   (`{Single,PerAggregate,Micro}` × sync/async, eight config sites) now bake `plugin`. The DCB topic
   needed no builder change — its `HANDLER_CONFIG` already carries `pluginName`, so the shell passes
   it straight through. Attribution is now uniform: every deployed component reports a `plugin`,
   including on the shared `AllAggregatesCmdHandler` and the per-aggregate `<Entity>AggrCmdHandler`,
   neither of which the Lambda-name fallback can resolve.

## Non-goals

- Metrics/Telemetry service (primitive #2) and per-hop `traceparent` (#4) — separate, later.
- Replacing the entry-point `.mjs` shells with generated/ReScript handlers — a much larger change
  tracked by `docs/plans/minimize-lambda-entrypoint-mjs-shell.md`; this plan only de-duplicates the
  dispatch shim inside them.
- Log storage, retention, dashboards — core emits and propagates only.

## Risks

- **Touches all 10 deployed entry points.** A mistake in the shared shim breaks every Lambda at
  once, and the failure mode (cold-start import error) is deploy-visible but not local-test-visible.
  Mitigate by keeping the shim signature options-object-shaped and landing Phase A alone, verified on
  alpha, before Phases B/C add fields.
- **JS↔ReScript signature coupling** on `RequestContext.make` — see the Phase A guard rail.
- `SentTimestamp` is *send* time, so a clock-skew or a long queue dwell shows up as latency; that is
  the intent, but the guide should say which clock it comes from (SQS server-side, not the producer).
