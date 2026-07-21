# Telemetry Substrate — the framework primitives observability layers consume

**Status:** Roadmap / consolidation analysis (no code)

**Created:** 2026-07-20

**Purpose:** Several telemetry-related threads have accumulated across separate plans and
analyses. This document consolidates them into one picture — what the framework already emits,
what is missing, and the order to build it — so downstream observability consumers (any layer
that reads logs / metrics / traces) have a stable, deliberate substrate rather than incidental
behaviour. It **does not replace** any existing plan; it sequences them and names the decisions.

**Consolidates:**
- `docs/plans/done/logging-output-optimization.md` (JSON log fields — done)
- `docs/plans/done/logging-harmonization.md` (`EffectLogger` + `~comp` — done)
- `docs/plans/done/effect-logger-and-request-context.md` (Effect logger + RequestContext — done)
- `docs/plans/done/identity-and-request-context.md` (RequestContext identity/claims — done)
- `docs/plans/queryable-dispatch-log-annotations.md` (comp + causationId on the invocation — **proposed; the first executable slice of this substrate**)
- `docs/analysis/request-context-usage.md` (dispatch-field menu — partial)
- `docs/analysis/effect-services-beyond-logging.md` (Metrics/Telemetry service — not implemented)

---

## What the framework already emits

- **Structured JSON logs** in non-TTY sinks, human-readable in a TTY (logging-output-optimization,
  verified in CloudWatch), with `correlationId`, `plugin`, and `comp` as **top-level fields**.
- **`correlationId` annotated for the whole invocation** at the `runEffect` dispatch boundary — so
  every log inside a handler inherits it.
- **Causal identity on the message envelope**: `Message.meta` carries `correlationId`,
  `causationId`, `msgId`, and `traceparent` (W3C Trace Context); `deriveMeta` inherits
  `correlationId`, sets `causationId = parent.msgId`, and mints a fresh `msgId`.
- **A per-invocation service injection point** (`runEffect`) already used to provide
  `RequestContext` — the natural attach point for any new Effect service.
- **Middleware pre/post hooks** and the **event topic** — the framework seams a consumer can wrap
  to observe execution without touching application code.

## The four primitives, and their status

| # | Primitive | What it enables | Status | Owner doc |
|---|---|---|---|---|
| 1 | **Log attribution** — `comp` + `causationId` on *every* line of an invocation | Isolate one component's logs in a shared runtime; reconstruct the causal tree from logs alone | **Done on both platforms** (AWS half 2026-07-21) — pending an on-AWS check, see the note below | `done/queryable-dispatch-log-annotations.md` + `done/eventcollector-element-level-log-comp.md` + `entrypoint-dispatch-parity-and-latency-fields.md` |
| 2 | **Metrics / Telemetry service** — an Effect service at dispatch (e.g. CloudWatch EMF) | Counters, histograms, timing emitted uniformly, provider-swappable, silenced in tests | Not implemented | `effect-services-beyond-logging.md` (§Metrics) |
| 3 | **Latency timing** — send-time `timestamp` (+ `retryCount`) in `RequestContext` | A handler computes processing latency without `Date.now()`; retry visibility | **Done** (2026-07-21) — both platforms; `retryCount` also surfaces as a log field on redelivery | `entrypoint-dispatch-parity-and-latency-fields.md` |
| 4 | **Per-hop `traceparent` rewrite** — update span/parent-id at each hop | Proper OpenTelemetry span *tree* (not just a flat trace-id) | `traceparent` is propagated **flat** (`deriveMeta` inherits as-is) | this doc (decision) |

### Platform-coverage note on primitive #1 (found and closed 2026-07-21)

**There are two dispatch boundaries, not one.** `Runtime.annotateInvocation` — the ReScript one —
does not execute on AWS: every deployed Lambda is an archive whose `index.handler` is a hand-written
entry-point shell, and the AWS runtime builders take `~handler as _` (the ReScript handler closure
is discarded; wiring happens at cold start inside the `.mjs` from `HANDLER_CONFIG`). Each of the ten
shells carried its own `runEffect` copy annotating only `correlationId` / `requestId` / `plugin`,
and provided `RequestContext` as a bare object literal — so on a deployed stack an application
handler's log line could not be attributed to a component and no `causationId` reached the log
stream, while the same code on `reventless-local` was fully annotated.

`entrypoint-dispatch-parity-and-latency-fields.md` replaced the ten copies with one shared shim in
`HandlerFactoryHelpers.mjs` and landed primitive #3 in the same pass (same extraction site). Keep
the two boundaries in step: a field added to one belongs in the other.

## The decision points

1. **Log-derived causality vs OTel spans.** Primitive #1 (causationId in logs) already yields a
   reconstructable causal tree from the log stream — cheap, no new infrastructure. Primitives #2/#4
   are the path to real spans + timing. Recommend **#1 first** (it is nearly free and rides the
   existing JSON logs); treat #2/#4 as the fidelity upgrade, not a prerequisite.
2. **`traceparent` semantics.** Today it is a flat trace-id grouping. Deciding whether the
   framework rewrites the span/parent-id per hop (true OTel) is a real but deferrable choice —
   only worth it once a consumer needs span-tree fidelity beyond what `causationId` gives.
3. **Open-core boundary.** The framework's job is to **emit** well-attributed logs/metrics and to
   **propagate** the correlation/causation/trace identity. Collecting, storing, querying, and
   visualizing telemetry lives in downstream consumers, not core. Every primitive above is
   emit-or-propagate; none is a collector.

## Recommended sequence

1. ~~**`queryable-dispatch-log-annotations.md`** (primitive #1) — small, unblocks per-component log
   isolation and log-derived causal trees immediately. Ship first.~~ Done on the ReScript dispatch
   boundary (2026-07-20/21, with `eventcollector-element-level-log-comp.md`).
2. ~~**`entrypoint-dispatch-parity-and-latency-fields.md`** — closes primitive #1 on AWS (one shared
   dispatch shim across the ten entry-point shells) and lands **primitive #3** (`timestamp` /
   `retryCount`) in the same pass, since both read the same SQS record.~~ **Implemented 2026-07-21**;
   on-AWS verification pending a deploy. Next up is step 3.
3. **Metrics/Telemetry service** (primitive #2) — the larger build; gives durations/histograms and
   feeds any latency view. Design the provider interface for EMF + an in-memory test accumulator.
4. **Per-hop `traceparent`** (primitive #4) — only when span-tree fidelity is actually required.

## Non-goals

Storage, retention, dashboards, alerting, trace/metric **collection or visualization** — all
downstream of the framework. Core emits and propagates; it does not consume.
