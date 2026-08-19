# Plan: a component's log line belongs to the invocation that caused it

**Date:** 2026-08-20
**Status:** Proposed — not started. Found by running the on-AWS verification that
[entrypoint-dispatch-parity-and-latency-fields.md](done/entrypoint-dispatch-parity-and-latency-fields.md)
had left open, against the deployed `online-shop-*-aws-alpha` stacks.
**Repos:** `reventless-core` only.

**Goal.** A framework component's log line carries the `correlationId`,
`causationId` and `plugin` of the invocation it is running inside — the guarantee
[Runtime.res:9-14](../../reventless/core/src/adapter/Runtime/Runtime.res#L9-L14)
already claims in prose and the dispatch boundary already computes.

**Non-goal.** Changing what the framework logs, the `comp` vocabulary, or
`Logger`'s level handling. The message text and `comp` of every line stay exactly
as they are; this is about the fields *around* them.

---

## The finding

The dispatch boundary annotates each invocation
([Runtime.res:15-60](../../reventless/core/src/adapter/Runtime/Runtime.res#L15-L60),
and its JS twin `runEffect` in `HandlerFactoryHelpers.mjs`):

```rescript
effect
->Effect.annotateLogs("correlationId", cid)
->annotateOpt("comp", comp)
->annotateOpt("causationId", causationId)
```

Component code then logs like this
([ReadModel_Callback.res:27-33](../../reventless/core/src/components/ReadModel/ReadModel_Callback.res#L27-L33)):

```rescript
EffectLogger.logInfo(~comp, ~detail=json, `handling event ${idxStr}/${total} …`)->Effect.runSync
```

`Effect.runSync` starts a **fresh fiber with default FiberRefs**. Log annotations
live in a FiberRef, so the boundary's annotations are not in scope: the only field
that survives is the `~comp` passed as an argument, which
[EffectLogger._annotate](../../reventless/core/src/util/EffectLogger.res#L162-L171)
attaches to the log effect itself.

[EffectLogger.res:154](../../reventless/core/src/util/EffectLogger.res#L154) documents
the detached form as a sanctioned usage — "usable in Effect pipelines or with
`->Effect.runSync`" — without noting that the second form silently drops whatever
the caller annotated.

### Measured on alpha

Deployed `online-shop-*-aws-alpha`, functions last modified 2026-08-19, log
events from the same day — so the code under observation postdates the dispatch-parity
work by a month.

| Log group | lines | top-level `comp` | `plugin` | `correlationId` | `causationId` |
| --- | --- | --- | --- | --- | --- |
| `…-AllAggregatesCmdHandler` | 202 | 141 | 20 | 20 | **0** |
| `…-AllReadModels` | 202 | 79 | **0** | **0** | **0** |
| `…-CatalogDcbCmdHandler` | 202 | 133 | 17 | 17 | **0** |

The `causationId` and `correlationId` hits that a naive `grep` finds in
`AllReadModels` are nested inside `detail.meta` — the event envelope, which
predates all of this — not top-level fields.

The split is exactly the mechanism above:

- The ~20 annotated lines per group are logged **at** the boundary, inside the
  annotated effect (`comp: "CommandGenerator(Customer)"`).
- Every deeper line is a component line run through `Effect.runSync`
  (`comp: "Aggregate(Customer)"`, `comp: "ReadModel(Customers)"`) and carries
  `comp` alone.
- `AllReadModels` has *no* annotated line at all, because every line it emits is a
  component line.

`plugin` is **not** missing from configuration — the deployed `HANDLER_CONFIG`
carries `{"comp": "EventCollector(CustomersReadModel)", "plugin": "Ordering"}`
per handler, and `StreamRoutedEntryPoint_Ops.makeRoutedHandler` passes both into
`runEffect`. It decorates a fiber whose annotations no component line ever reads.

`causationId` is 0 in these three groups for the same reason, compounded on the
command handlers by there being nothing to extract: an AppSync-triggered command
arrives with no `meta.correlationId`, which is why the annotated lines there read
`"correlationId":"unknown"`.

**The extraction itself is sound**, which is what makes this a log-plumbing defect
rather than a telemetry one. A boundary line on
`…-OrderingPluginEventColl` (2026-08-18 07:37:03Z) carries the complete set at
once, off an SQS message whose `meta` had all of it:

```json
{"plugin":"Ordering","comp":"Plugin(Ordering@1.0.0-alpha.213)","retryCount":"2",
 "correlationId":"27e56f2e-…","causationId":"bf0e704a-…","requestId":"…"}
```

Everything this plan wants on a component line is already computed, extracted and
attached one frame up. It just does not survive `Effect.runSync`.

## Why it matters

The dispatch-parity plan shipped the boundary, the extractors, the per-handler
`plugin` bake and a 13-case seam test, and all of it works. What it cannot deliver
on its own is the thing the telemetry substrate is for: taking one `correlationId`
and reading the whole causal chain across the ten Lambdas that share a log group.
Today that query returns the ~15% of lines emitted at a boundary and none of the
work.

It also makes `comp` do double duty. `comp` separates two components co-hosted in
one Lambda, which it does well. It cannot separate two *invocations* of the same
component — that is what `correlationId` is for, and it is absent from precisely
the lines that describe the work.

## Scope

109 detached call sites across 36 files (`EffectLogger.log*(…)->Effect.runSync`):

| n | file |
| --- | --- |
| 10 | `components/Aggregate/Aggregate_Callback.res` |
| 9 | `util/CommandPublisher.res` |
| 8 | `components/Extension/Extension_Operations.res` |
| 7 | `components/EventMapper/EventMapper_Callback.res` |
| 7 | `components/ExtensionPoint/ExtensionPoint_Operations.res` |
| 6 | `util/FTPHandler.res` |
| 6 | `plugin/connect/PluginExtensionPoint_Plugin.res` |
| 5 | `adapter/Runtime/AggregateRuntime_Builder_Common.res` |
| 4 | `components/Counter/Counter_Operations.res` |
| … | 27 further files at 1–3 each, incl. `reventless/aws` (5) and `reventless/local` (2) |

Reproduce the census with the script in §Verification.

## Design

Three mechanisms are possible. They are not equivalent, and the choice is the
substance of this plan.

### Option A — thread the log effect into the caller's chain

Replace `EffectLogger.logInfo(…)->Effect.runSync` with a log effect sequenced into
the surrounding effect, so it runs on the annotated fiber.

- **Correct by construction** — annotations are FiberRefs, and the line runs on
  the right fiber. No ambient state, no concurrency hazard.
- **Invasive.** Many sites sit inside callbacks that return a plain value, not an
  effect — `ReadModel_Callback`'s is inside an `Array.mapWithIndex` whose result
  is an actions array. Threading the log means restructuring the callback into an
  effect and folding it, which changes control flow at 109 sites.
- Risk of behaviour change: a log currently emitted eagerly becomes ordered with
  the rest of the chain. For the sites inside a fold this is what we want; for a
  site logging *before* a throw it needs checking one by one.

### Option B — an ambient invocation record, set at the boundary

`Runtime.annotateInvocation` (and its `runEffect` twin) additionally set a
module-level "current invocation" holding `correlationId` / `causationId` /
`retryCount`; `EffectLogger.install`'s handler merges those into `extra` when the
annotation map does not already carry them.

- **Small and uniform** — two writers, one reader, no call-site edits, so all 109
  sites are fixed at once and future ones cannot regress.
- **Precedent exists** — `HandlerFactoryHelpers.mjs` already keeps
  `_currentRequestId` this way, set by `setRequestId(ctx.awsRequestId)` at handler
  entry, and `requestId` is the one field that already appears correctly.
- **Concurrency hazard, and it is real.**
  `StreamRoutedEntryPoint_Ops.makeRoutedHandler` maps over source groups with
  `Array.map(async …)->Promise.all`
  ([StreamRoutedEntryPoint_Ops.res:120-154](../../reventless/aws/src/adapter/Runtime/StreamRoutedEntryPoint_Ops.res#L120-L154)),
  so two groups with **different** `correlationId`s are in flight in one
  invocation. A single mutable slot would attribute a line to whichever group
  wrote last. Within one group the handlers share a `correlationId` and differ
  only in `comp`/`plugin`, which are already passed per site — so the hazard is
  precisely cross-group, and a fix must scope the record per group rather than
  per invocation.

### Option C — run the detached log on the caller's runtime

Capture `Effect.runtime()` at the boundary and use its `runSync` at the log site,
so the fresh fiber inherits the captured FiberRefs.

- Keeps the eager, non-effect call shape that the 109 sites are written against.
- Still needs the runtime handed to each site — which is Option B's ambient-state
  problem with a heavier value in the slot, or Option A's threading with an extra
  parameter.
- Adds an Effect API dependency at every component boundary for a gain the other
  two already give.

### Recommendation

**Option A for the component callbacks, measured first.** It is the only one
without an ambient-state hazard, and the concurrency hazard in B is not
hypothetical — the routed handler that hosts every read model is exactly the
shape that breaks it. Option B remains attractive as a *backstop* for the
utility-code sites (`FTPHandler`, `Validation`, `Util_Promise`) that have no
enclosing effect to thread, provided the record is scoped per source group.

Phase 1 exists to make that split on evidence rather than on this paragraph.

## Phases

Each lands and is verifiable on its own.

### Phase 1 — a failing test, and the census

- A test that asserts what alpha disproves: dispatch a component handler through
  `Runtime.runEffectHandler` with a known `correlationId`/`causationId`, capture
  the emitted lines, and assert an **inner** component line carries both. It must
  fail on today's tree — that is what makes it the regression guard.
- Classify all 109 sites into *has an enclosing effect chain* (Option A) and
  *does not* (needs B or a signature change). The counts decide the shape of
  Phase 2 and belong in this file when known.

### Phase 2 — thread the component callbacks

Convert the Option A sites, component family by component family, starting with
the two the alpha measurement covers (`ReadModel_Callback`, `Aggregate_Callback`)
so the fix is observable on the same log groups. Each family is its own commit.

### Phase 3 — the remainder

Whatever Phase 1 classified as un-threadable: either a scoped ambient record per
Option B, or a signature change carrying the invocation explicitly. Decide with
Phase 1's numbers in hand.

### Phase 4 — close the seam

- `EffectLogger.res:154`'s comment stops presenting `->Effect.runSync` as an
  equivalent usage and says what it costs.
- `docs/guides/cloudwatch-logs-insights.md` gains a "one correlationId, whole
  chain" query, which is the query this plan makes answerable.

## Acceptance

- A component log line emitted inside a dispatched invocation carries
  `correlationId`, and carries `causationId` and `plugin` when the invocation has
  them.
- A CloudWatch filter on one `correlationId` returns the component lines of that
  invocation, not just its boundary lines.
- Two source groups concurrent in one `AllReadModels` invocation never borrow each
  other's `correlationId`.
- `comp` is unchanged on every line; no message text changes.
- Zero compiler warnings; the full suite stays green.

## Verification

Census (expect 109 across 36 before Phase 2, and a shrinking count after):

```bash
python3 - <<'PY'
import re,glob
tot=0
for root in ("reventless/core/src","reventless/aws/src","reventless/local/src"):
    for p in glob.glob(root+"/**/*.res",recursive=True):
        s=open(p).read(); n=0
        for m in re.finditer(r'EffectLogger\.log(Info|Warn|Error|Debug)\s*\(', s):
            i=m.end()-1; d=0
            while i<len(s):
                if s[i]=='(': d+=1
                elif s[i]==')':
                    d-=1
                    if d==0: break
                i+=1
            if re.match(r'\s*->\s*Effect\.runSync', s[i+1:i+40]): n+=1
        if n: print(f"{n:4d}  {p}"); tot+=n
print("TOTAL", tot)
PY
```

**On AWS** — re-run the measurement that produced the table above against
`…-AllReadModels` after Phase 2 and require a non-zero `correlationId` count on
component lines. This is the same check
[entrypoint-dispatch-parity-and-latency-fields.md](done/entrypoint-dispatch-parity-and-latency-fields.md)
left open, and closing it here is what lets that plan close too.

## Risks

- **Ordering.** Threading a previously-eager log into a chain changes when it is
  emitted. Sites that log immediately before raising need reading individually.
- **Breadth.** 109 sites across three packages; a mechanical sweep that compiles
  is not evidence it still logs. Phase 1's test is the thing that makes the sweep
  checkable, which is why it comes first.
- **Ambient state, if Phase 3 goes that way.** A per-invocation slot is wrong on
  the routed handler; only a per-source-group scope is safe. Getting this wrong
  produces *confidently mislabelled* lines, which is worse than the missing
  fields this plan started from.
