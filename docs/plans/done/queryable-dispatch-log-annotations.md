# Component + Causation Log Annotations at the Dispatch Boundary

**Status:** Complete (2026-07-20)

**Created:** 2026-07-20

**Shipped:**
- **Phase A/C** — one shared dispatch helper in `Runtime.res`: `annotateInvocation`
  + `runEffect` (multi-component dispatchers) and an upgraded `runEffectHandler`
  (single-component-per-Lambda strategies). Both annotate `correlationId`, `comp`,
  and `causationId` and provide a populated `RequestContext`. The private
  `runEffect` copies in `AggregateRuntime_Builder_Common` and
  `EventCollectorRuntime_Builder_Single` are gone; every per-component builder
  (core Micro/Plugin/PerEventCollector/PerExtensionPoint + `reventless-local`)
  threads the component `comp` and the Environment's extractors into
  `runEffectHandler`.
- **Phase A extraction** — `extractCausationId` added to the `Runtime.Environment`
  module type and both implementations (`RuntimeEnvironment_Lambda`,
  `LocalRuntimeEnvironment`), factored through a shared `extractMetaField`.
- **Phase B** — `RequestContext.t` gained optional `causationId` / `component` /
  `pluginName`; a real `make` constructor is used at dispatch; `.test()` is now
  test-only (no non-test source calls it).
- **Phase D** — `docs/guides/cloudwatch-logs-insights.md` documents `causationId`,
  the "`comp` on every line" guarantee, and a causal-chain query.

Full monorepo build green (zero warnings); `IdentityTest`, `LogFormatTest`,
`MessageTest`, `MetaEnvelopeTest`, `AggregateCausationTest` pass.

**Builds on (all complete):**
`docs/plans/done/logging-output-optimization.md` — clean JSON in cloud sinks; `comp` / `plugin` /
`correlationId` already lift to **top-level JSON fields**; verified in alpha CloudWatch incl. a
correlationId trace across a SQS hop.
`docs/plans/done/logging-harmonization.md` — `EffectLogger` with the `~comp` parameter; dispatch
logs routed through it.
`docs/plans/done/effect-logger-and-request-context.md` — Effect logger + `RequestContext` provided
at dispatch.
`docs/plans/done/identity-and-request-context.md` — `RequestContext` expanded with identity + claims.

**Predecessor analysis:** `docs/analysis/request-context-usage.md` (recommended `causationId`;
not implemented).

**Summary:** The structured-logging foundation is already shipped — logs render as JSON in cloud
sinks with `correlationId`, `plugin`, and `comp` as queryable top-level fields. This plan closes
the **two remaining gaps** that keep logs from being filterable *per component* and *per causal
chain*:

1. **`comp` is annotated only on the framework's own log lines, not on the invocation.** An
   application handler's own `Effect.logInfo` inherits `correlationId` and `plugin` but **not**
   `comp` — so its lines can't be attributed to a component. In a runtime process that hosts many
   components (e.g. an all-aggregates command handler), this is exactly what's needed to isolate
   one component's logs.
2. **`causationId` is dropped** — neither annotated on logs nor carried in `RequestContext`, so the
   parent → child causal chain of one operation is not reconstructable from logs (only the flat
   `correlationId` grouping is).

Both values already exist at the dispatch site; the work is to annotate them onto the invocation
effect (like `correlationId` already is) and to stop using the `.test()` context at real dispatch.

---

## What already ships (do NOT redo)

- **JSON output** in non-TTY sinks, human-readable in a TTY — `logging-output-optimization`
  (Tiers 1–3), verified end-to-end in CloudWatch.
- **`correlationId` annotated for the whole invocation** — `runEffect` in
  `AggregateRuntime_Builder_Common.res` (and `EventCollectorRuntime_Builder_Single.res`) does
  `->Effect.annotateLogs("correlationId", cid)`, so every log inside the handler carries it.
- **`comp`, `plugin`, `correlationId` are top-level JSON fields** — `EffectLogger.install()`
  decodes the annotations into fields; `plugin`/`pluginName` resolved via the entry-point shim.
- **`traceparent` on `Message.meta`** — preserved for later trace correlation.

## The precise gaps (with code refs)

- `runEffect(~correlationId=?, effect)` annotates `correlationId` but **not** `comp`. The `comp`
  value is already computed one scope out (`let comp = \`AggregateRuntime(${aggregateName})\``,
  `AggregateRuntime_Builder_Common.res:47`) and passed to individual `EffectLogger.logDebug(~comp, …)`
  framework lines — but never onto the effect that runs the application handler.
- `runEffect` provides `RequestContext.test(~correlationId=cid)` at the **real** dispatch (line 40),
  and `RequestContext.t` carries `correlationId` (+ identity/claims) but **no `causationId`, no
  `comp`, no `pluginName`, no `msgId`**.
- `causationId` is available (`Message.meta.causationId`, propagated by `deriveMeta`) but never
  reaches the logs or the context.

## Design (small delta)

### Phase A — Annotate `comp` and `causationId` on the invocation
Extend the dispatch wrapper to take the component and causation id and annotate both onto the
effect, alongside the existing `correlationId`:

```
let runEffect = (~correlationId=?, ~comp=?, ~causationId=?, effect) => {
  let cid = correlationId->Option.getOr("unknown")
  effect
  ->Effect.annotateLogs("correlationId", cid)
  ->annotateOpt("comp", comp)
  ->annotateOpt("causationId", causationId)
  ->Effect.provideService(RequestContext.tag, ctx)   // real ctx, see Phase B
  ->Effect.runPromise
}
```

Pass `~comp` (the already-computed component string) and `~causationId`
(`event.meta.causationId`) at each call site. Result: an application handler that only calls
`Effect.logInfo` now emits `comp` + `causationId` as fields for free — component isolation works
for every line, not just framework lines.

### Phase B — Populate `RequestContext` properly at dispatch
Replace `RequestContext.test(~correlationId=cid)` at the real dispatch with a real constructor
carrying `correlationId`, `causationId`, `component`, `pluginName` (plus the existing identity /
claims). `.test()` should be test-only. Add the fields to `RequestContext.t` (this is the
`causationId` field `request-context-usage.md` recommended and left unimplemented).

### Phase C — Cover all runtime builders (and de-duplicate)
`runEffect` is copy-defined across builders (`AggregateRuntime_Builder_Common`,
`EventCollectorRuntime_Builder_Single`, and the projection / side-effect paths). Consolidate into
one shared dispatch helper so `comp`/`causationId` annotation is uniform and can't be forgotten in
one path. `comp` is per-component, so this is what makes a component's logs separable inside a
shared runtime process.

### Phase D — Document the field contract
Extend the logging guide's field list (already documenting `correlationId`/`plugin`/`comp` from
`logging-output-optimization`) to include `causationId`, and state that `comp` is guaranteed on
**every** line within a handler invocation (not just framework lines). Application handlers should
not re-log these by hand.

## Acceptance

- An application handler that only calls `Effect.logInfo("…")` emits a JSON line carrying
  `comp`, `correlationId`, and `causationId` as top-level fields.
- Two components hosted in one runtime process are separable purely by the `comp` field.
- `causationId` reconstructs the parent → child chain within one `correlationId`.
- No runtime builder retains a private `runEffect` that skips the annotations.
- Existing `logging-output-optimization` behaviour (JSON in cloud, human in TTY, no ANSI in
  `message`) is unchanged.

## Non-goals

- JSON output / sink formatting — **already done** (`logging-output-optimization`); no change.
- Log storage, retention, shipping, querying, or visualization — core only emits.
- Distributed trace spans — `traceparent` is preserved; span emission is separate.
- Changing `meta` semantics or `deriveMeta` propagation (already correct).

## Relationship to the other logging plans

The four `done/` plans are complete and correct and need **no changes**; this plan is a narrow
delta on top of them. The one document worth a forward-pointer is the `request-context-usage.md`
analysis, whose recommended-but-unimplemented `causationId` field is picked up here (Phase B).
