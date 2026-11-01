# Plan: a component's log line belongs to the invocation that caused it

**Date:** 2026-08-20, revised 2026-11-01<br/>
**Status:** ✅ Built 2026-11-01, not yet released; the AWS measurement of
[Verification](#verification) is still to be made after a deploy. Decided the same day (the open
questions as recommended), after a revision against today's code: a fourth mechanism
([Option D](#option-d--the-handled-messages-ids-on-the-log-call)) is recommended, and the steps
are numbered [CL1 to CL5](#phases). Found by running the on-AWS verification that
[entrypoint-dispatch-parity-and-latency-fields.md](done/entrypoint-dispatch-parity-and-latency-fields.md)
had left open, against the deployed `online-shop-*-aws-alpha` stacks.<br/>
**Repos:** `reventless-core` only.<br/>
**Unblocks:** [PF9 of the-local-platform-serves-what-is-watched.md](the-local-platform-serves-what-is-watched.md#pf9-ids-on-every-log-line),
which puts the handled message's own id and its entity on the same lines.

> **Questions and short answers**
>
> - *What is wrong?* **A component's log line loses the ids of the flow it works for.** The
>   dispatch boundary annotates the fiber; component code logs through `Effect.runSync`, a fresh
>   fiber, so only the `~comp` it passes survives ([the finding](#the-finding)).
> - *How is it fixed?* **The log call carries the ids of the message being handled**, the way it
>   already carries `~comp`: annotations on the log effect itself survive `runSync`. Every
>   component callback has that message at hand ([Option D](#option-d--the-handled-messages-ids-on-the-log-call),
>   [CLQ1](#open-questions)).
> - *Why not thread the effect, as first recommended?* **Threading is right per invocation, and
>   an invocation is the wrong unit.** One aggregate batch can hold commands of several flows,
>   and the boundary annotates one `correlationId` per batch; the handled message is the only
>   exact source. It also leaves the 134 call sites' shape as it is.
> - *What does it add beyond the ids the boundary had?* **The handled message's own `msgId`,
>   and the entity a command is handled for** ([CL3](#cl3-the-component-families)), which [PF9](the-local-platform-serves-what-is-watched.md#pf9-ids-on-every-log-line)
>   asks for.

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

### Measured locally too — this is not an AWS defect

A seeded in-memory `online-shop-hybrid` run, 2026-08-20, classifying every
component log line by whether it carries a top-level `correlationId`:

| `comp` prefix | with `correlationId` | without |
| --- | --- | --- |
| `StateChangeSlice` | 0 | 1331 |
| `StateViewSlice` | 0 | 482 |
| `ExtensionPoint` | 0 | 447 |
| `Extension` | 0 | 312 |
| `ReadModel` | 0 | 191 |
| `CommandTopic` | 0 | 132 |
| `CommandGenerator` | 0 | 113 |
| `Aggregate` | **12** | 123 |
| `Plugin` (the dispatch boundary) | 333 | 0 |

Roughly **90% of component log lines carry no `correlationId` on the local
platform**, where `Runtime.annotateInvocation` demonstrably *does* run — the
`Plugin` row is that boundary working exactly as designed.

This matters for scoping. The AWS measurement above could be read as an
entry-point-shell problem, and it is not: both platforms annotate correctly and
both lose it at the same place. `Aggregate`'s split — 12 annotated against 123
not — is the mechanism in miniature within a single component: the lines that
happen to sit in the effect chain keep the annotations, and the `Effect.runSync`
lines beside them do not.

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

134 detached call sites across 40 files on 2026-11-01 (`EffectLogger.log*(…)->Effect.runSync`;
109 across 36 when this plan was written):

| n | file |
| --- | --- |
| 12 | `components/Aggregate/Aggregate_Callback.res` |
| 12 | `components/AutomationSlice/AutomationSlice_Callback.res` |
| 10 | `components/OutboundTranslationSlice/OutboundTranslationSlice_Callback.res` |
| 9 | `util/CommandPublisher.res` |
| 8 | `components/Extension/Extension_Operations.res` |
| 7 | `components/EventMapper/EventMapper_Callback.res` |
| 7 | `components/ExtensionPoint/ExtensionPoint_Operations.res` |
| 6 | `util/FTPHandler.res` |
| 6 | `plugin/connect/PluginExtensionPoint_Plugin.res` |
| 5 | `adapter/Runtime/AggregateRuntime_Builder_Common.res` |
| … | 30 further files at 1–4 each, incl. `reventless/aws` (7) and `reventless/local` (6) |

Reproduce the census with the script in [Verification](#verification).

**Since this plan was written:**

- `ViewChange` writes its `view changed` line through `Logger.emit` with the source events' ids
  as annotations: the same idea as [Option D](#option-d--the-handled-messages-ids-on-the-log-call),
  already working on one line.
- Commands an automation or an outbound translation sends now continue their event's flow
  (`Message.deriveMetaFromSource`), so a command's own meta carries the flow's ids.
- `StateViewSlice_Callback.eventsHandler` is a promise, not an effect: Option A cannot thread
  it without converting it.
- One aggregate batch can carry commands of different flows, and the boundary annotates the
  batch with one `correlationId`. A line per command needs the command's own ids.

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
- Risk of behavior change: a log currently emitted eagerly becomes ordered with
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

### Option D — the handled message's ids on the log call

`EffectLogger`'s helpers take the ids of the message being handled, as they take `~comp`, and
attach them as annotations **on the log effect itself**. `_annotate` already does this for
`comp` and `detail`, which is why `comp` survives `Effect.runSync` today.

- **Exact per message.** A component callback always has the message it handles (a command's
  meta, an event's envelope); its ids are the ones the line is about, also when one batch holds
  several flows.
- **No hazard.** No ambient state and no fiber to thread; a call site gains one argument.
- **Adds what the boundary never had:** the message's own `msgId`, and the entity a command is
  handled for ([PF9](the-local-platform-serves-what-is-watched.md#pf9-ids-on-every-log-line)).
- **Cannot reach a line with no message at hand:** utility code (`FTPHandler`, `Validation`,
  `Util_Promise`) and cold reads. Those keep the boundary's annotations only where they are in
  its chain ([CL4](#cl4-the-remainder)).

### Recommendation

**Option D for every site that handles a message** ([CLQ1](#open-questions)). The boundary
annotation stays as it is, for the lines that run in its chain; where both name a field, the log
call's value wins, since it names the message the line is about. Option A stays right for a site
that is already in an effect chain and has no message of its own; Option B is not needed.

## Phases

Numbered CL1 to CL5. Each lands and is verifiable on its own.

### CL1: a failing test, and the census

- A test that asserts what alpha disproves: run a component handler through
  `Runtime.runEffectHandler` with two commands of different flows in one batch, capture the
  lines, and assert each **inner** line carries its own command's `correlationId`, `causationId`
  and `msgId`. It fails on today's tree.
- Classify the 134 sites into *has the handled message at hand* ([CL3](#cl3-the-component-families))
  and *does not* ([CL4](#cl4-the-remainder)), and write the counts into this file.

### CL2: the log call takes the message's ids

- `EffectLogger.logInfo`, `logWarn`, `logError` and `logDebug` take an optional `~ids`: a record
  of the optional `msgId`, `correlationId`, `causationId`, `entityId` and `entityType`,
  annotated on the log effect like `~comp`. A helper builds it from a `Message.meta`.
- `install()` already turns every other annotation into a top-level field, so the JSON line and
  the log record gain the fields with no change there; a field the call names wins over the
  fiber's.
- **Exit:** a `LogFormatTest` case in which a detached line carries the ids it was given, and a
  case in which the call's `correlationId` wins over the boundary's.

### CL3: the component families

One family per commit, each passing its message's ids, in this order (the first two are the
alpha log groups, so the fix is measurable there):

1. `ReadModel_Callback` and `StateViewSlice_Callback`: the event's meta.
2. `Aggregate_Callback`: each command's meta, and `entityId` and `entityType` (the aggregate id
   and its name) on the lines of its handling.
3. `StateChangeSlice_Callback`: the command's meta, and the entity it decides on
   ([CLQ2](#open-questions)).
4. `AutomationSlice_Callback`, both translation slices, `EventMapper_Callback`: the triggering
   event's meta, and the command's on the lines about the command it sends.
5. `CommandTopic`, `CommandPublisher`, `Extension*`, `ExtensionPoint*`, `Counter*`,
   `SideEffectHandler_Callback`, `ScheduleOps`: the message each handles.

- **Exit:** [CL1](#cl1-a-failing-test-and-the-census)'s test passes; each family's existing
  tests pass unchanged.

### CL4: the remainder

The sites [CL1](#cl1-a-failing-test-and-the-census) finds with no message at hand stay as they
are, unless one sits in an effect chain, where it is threaded (Option A). Their lines describe
the platform, not a flow.

### CL5: close the seam

- `EffectLogger`'s comment on the detached form says what it costs, and points to `~ids`.
- `docs/guides/cloudwatch-logs-insights.md` gains the "one correlationId, whole chain" query,
  with `msgId` in its field list (together with
  [PF12](the-local-platform-serves-what-is-watched.md#pf12-the-cloudwatch-guide-follows-the-chain)).

## Decisions

| # | Decision | Decided | Why |
| --- | --- | --- | --- |
| CLD1 | Where a line's ids come from | **the message being handled, on the log call; the boundary's fiber where the line is in its chain** | per message is exact even when a batch mixes flows ([CLQ1](#open-questions)) |
| CLD2 | Field names | **the ones the platform's lines already use: `msgId`, `correlationId`, `causationId`, `entityId`, `entityType`** | the `view changed` line and the outcome records name them so; one query reads all |
| CLD3 | Message text and `comp` | **unchanged** | this plan is about the fields around a line |

## Open questions

**CLQ1. Option D, or Option A as first recommended?** **Recommendation:** Option D. It is exact
where A is approximate (a batch of several flows has one boundary annotation), it reaches the
promise-based `StateViewSlice` callback without converting it, and it leaves the control flow of
134 sites as it is. Option A stays for the few sites in a chain with no message of their own.

**CLQ2. What is the `entityType` of a DCB slice's command?** The slice decides on an entity named
by its partition tag; a composite or by-event-type partition names no single one.
**Recommendation:** the partition tag's key, and the tag's value as `entityId`, for a simple
partition; neither for the others. `ViewChange` names a DCB event's entity by its first tag's key
and value, so a command's lines and the rows its events changed join on the same pair.

## Acceptance

- A component log line about a message carries that message's `msgId` and `correlationId`, and
  its `causationId` and `plugin` when it has them; a command's handling lines carry its entity.
- Two commands of different flows in one batch each keep their own ids on their lines.
- A CloudWatch filter on one `correlationId` returns the component lines of that
  invocation, not just its boundary lines.
- Two source groups concurrent in one `AllReadModels` invocation never borrow each
  other's `correlationId`.
- `comp` is unchanged on every line; no message text changes.
- Zero compiler warnings; the full suite stays green.

## Verification

Census (134 across 40 on 2026-11-01; the count of sites without `~ids` shrinks with each
[CL3](#cl3-the-component-families) family):

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
`…-AllReadModels` after [CL3](#cl3-the-component-families) and require a non-zero `correlationId` count on
component lines. This is the same check
[entrypoint-dispatch-parity-and-latency-fields.md](done/entrypoint-dispatch-parity-and-latency-fields.md)
left open, and closing it here is what lets that plan close too.

## Risks

- **Ordering**, only where [CL4](#cl4-the-remainder) threads a site: a previously eager log
  becomes ordered with its chain. Sites that log immediately before raising are read one by one.
- **Breadth.** 134 sites across three packages; a sweep that compiles is not evidence it
  still logs. [CL1](#cl1-a-failing-test-and-the-census)'s test makes the sweep checkable,
  which is why it comes first.
- **The wrong message.** A site that passes the ids of a message other than the one its line is
  about labels the line confidently and wrongly. Each family's commit is read site by site.

## As built

Built on 2026-11-01, as [CLQ1](#open-questions) and [CLQ2](#open-questions) recommend.

| Step | Built | Where |
| --- | --- | --- |
| [CL1](#cl1-a-failing-test-and-the-census) | ✅ | `ComponentLineIdsTest`: two commands of different flows in one aggregate batch, each `handling command` line with its own `msgId`, `correlationId` and entity; it failed before [CL3](#cl3-the-component-families) |
| [CL2](#cl2-the-log-call-takes-the-messages-ids) | ✅ | `EffectLogger.ids`, `idsOf` (a meta), `idsOfSource` (a work item's triggering event), `idsOfJson` (a message as JSON); `~ids` on the four helpers |
| [CL3](#cl3-the-component-families) | ✅ | aggregate, DCB slice, read model, state-view slice and builder, automation slice, outbound translation, event mapper, side-effect handler, command topic, extensions and extension points, event topic and event log publishing |
| [CL4](#cl4-the-remainder) | ✅ | left as they are; see the census below |
| [CL5](#cl5-close-the-seam) | ✅ | `EffectLogger`'s comment; `docs/guides/cloudwatch-logs-insights.md` gains `msgId`, `entityId` and `entityType` in its field list, and queries for the rows one flow changed, one entity's history and refusals before the handler |

**The census after [CL3](#cl3-the-component-families):** 135 detached sites, 49 of them with the
ids of the message they are about. The other 86 describe a batch or the platform, not one
message: the command publisher's chunks, the FTP handler, publish hooks' errors, the plugin
extension point's forwarding, the runtime dispatcher's bookkeeping, schedule and restore lines.
The DCB slice's lines in its effect chain carry the command's ids too.

**Details the steps left open:**

- **An aggregate's lines about one entity** (replay, snapshots, append, conflict) carry the
  entity, and the flow and `msgId` only when the batch holds one command or one flow.
- **A DCB slice's entity** is its simple partition tag's value and key; a composite or
  by-event-type partition names none on the lines ([CLQ2](#open-questions)).
- **A work item's lines** (automation, outbound translation) carry the triggering event's
  `msgId` and `correlationId`, from the row's `source`; a row without one carries none.

