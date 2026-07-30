# Plan: the create path for a new plugin stack

**Date:** 2026-07-29, updated 2026-07-30
**Status:** **A plugin stack can be created from scratch again.** Both `catalog-aws` and `ordering-aws`
deploy clean on `pr-verify`. 1b fixed and deploy-verified. 1a turned out not to be fixed — it replaced a
crash with a silently missing Lambda, and the deeper truth was that a side-effect handler's Lambda had
*never* been provisioned on AWS by any path — reopened and fixed as **defect 3**, verified by the
`AllSideEffectHandlers` Lambda actually existing. **Defect 2 does not reproduce** and is downgraded from
blocker to recorded latent race. None of this affects an existing stack.

**Found by:** the first-ever deploy of `online-shop-aggregates`, standing up the `PlatformOwned`
serving arm — see [declared-object-stores-without-host-ui-bundle.md](../declared-object-stores-without-host-ui-bundle.md).

**Verification loop is much cheaper than recorded.** `pulumi preview` against a warm `pr-verify`
stack reproduces the export-serialization failures in ~40s with no AWS writes; the plan previously
assumed only a full `up` would do. Use preview to iterate, one `up` to confirm. The earlier note that
previews skip `EventMapper_Builder`'s `.apply` holds only for a *cold* stack — once the inputs are
known, the apply runs.

## Why these were invisible

Every deployed plugin stack was created long ago and is only ever *updated*. Nothing had created one
from scratch in a long time, so the create path had no coverage of any kind — not CI, not a preview,
not a deploy. Two of the defects that path contained were fixed earlier (a missing generated deploy
root, and SDK command names that named the Pulumi resource rather than the AppSync operation,
`777c8ff7e`); 1b and 3 are fixed here; 2 turned out not to reproduce.

The shared lesson is worth stating separately from either fix: **"the deploy is green" has never
meant "this stack could be built again."** An update-only path exercises a different code path from
create, and for dynamic providers it does not even re-run the same serialized closure.

## Defect 1 — Effect captured in a serialized Lambda closure

`RuntimeEnvironment_Lambda.make` builds a Lambda with `Lambda.CallbackFunction.make(~callback=…)`,
which makes Pulumi serialize the handler closure into stack state. The handler comes from
`Runtime.runEffectHandler`, whose returned `(event, ctx) => …` closes over `Effect`. Pulumi's closure
walker cannot serialize it. The chain, verbatim from the deploy:

```
'(event, ctx) => { let extract = (f, …': Runtime.res.mjs(33,9): captured
  variable 'Effect' which indirectly referenced
    … runtime.js unsafeRunPromiseExit → unsafeFork → scheduler_ →
      Scheduler.js(100,50): which could not be serialized because
        arrow function captured 'this'.
```

**This is already documented at the call site.** [RuntimeEnvironment_Lambda.res:25-33](../../../reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res#L25)
states that the closure walker fails on Effect-TS, that the failure is normally *silent* so the
Lambda is simply never created while the deploy still reports success, that
`docs/plans/done/complete-bundled-migration.md` records an ordering-aws deploy coming up four Lambdas
short, and that converting the remaining builders to a compiled entry point is the fix. So this is
known debt with a known remedy, not a discovery. What is new is a reproduction.

**It did not stay silent here, and that is the interesting part.** The failed serialization yields an
undefined Lambda (`Successfully created undefined` appears in the log), which
`Plugin_Helpers.res.mjs:630` then threads into `Pulumi.Output.flatMap` — and `flatMap` is
`m->map(f)->unwrap` over a `%identity` cast, so a non-Output `m` throws `m.apply is not a function`.
The *reported* error is that TypeError; the serialization failure is printed alongside it as a second
error. Read in the wrong order it looks like an Output bug in `Plugin_Helpers`.

That accident is now the only thing making this class of failure loud. Worth keeping rather than
smoothing over: a silent missing Lambda is strictly worse than a crash.

**Remaining callers of the serializing path** (`RuntimeEnvironment.make`, all in `reventless/core`):
`PluginRuntime_Builder_Micro`, `PluginRuntime_Builder_Single`, `AggregateRuntime_Builder_Micro`,
`AggregateRuntime_Builder_Single`, `EventCollectorRuntime_Builder_Single`. Every AWS plugin builder
already uses `makeFromCodeAsset`, the compiled-entry-point path, which is why most components are
unaffected.

**The trigger condition is the EventMapper, and it is confirmed from the crash site.** The TypeError's
stack lands on `Plugin_Helpers.res.mjs:630` = `serializeEventMappersOutputs`, walking
`Stdlib_Array.filterMap` → `Stdlib_Option.map(agg.eventMapper, …)` → `Output.flatMap`. So
`agg.eventMapper` is `Some(x)` where `x` is not an Output — an EventMapper whose Lambda never
materialised.

[Aggregate_Builder.res:44](../../../reventless/core/src/components/Aggregate/Aggregate_Builder.res#L44)
gates it: `if EventMappings.mappings->Array.length > 0` builds the EventMapper, else `eventMapper`
stays absent. So **only an aggregate that declares EventMappings reaches this path**, which explains
the whole distribution of the failure exactly:

| Example | EventMappings on an aggregate? | Outcome |
|---|---|---|
| `online-shop-hybrid` | no — slice-based | never builds an EventMapper, deploys fine |
| `online-shop-aggregates` / catalog | no `_Mappings.res` | got far enough to fail on defect 2 instead |
| `online-shop-aggregates` / ordering | yes — `Order/Aggregate/Order_Mappings.res` | **fails here** |

Earlier guesses at the Task and the SideEffect were wrong; both are on compiled paths. That matters
for the fix: it is not the call-site comment's "side-effect-bearing Task" surface, so the conversion
target is whatever the EventMapper path uses, not one of the builders that comment names.

**Reproduced locally, and the component is named.** A from-scratch `pulumi up` of `ordering-aws`
against a throwaway platform stack reproduces the failure identically in about four minutes — a far
better loop than a CI cycle. `pulumi stack export` on the half-built stack shows the EventMapper
exists as a component while its Lambda does not:

```
reventless:EventMapper     OrderAggr
reventless:EventCollector  OrderAggrEventMapper     ← no Lambda
Lambdas created: AllAggregatesCmdHandler, AllReadModels, DeadLetterQueue,
                 OrderingOrdersExtPointCmdHandler, OrderingPluginEventColl,
                 OrderingPluginHeartbeat
```

So the target is the EventMapper's own EventCollector (`OrderAggrEventMapper`) — every other
component got its Lambda from a compiled entry point.

**A preview cannot substitute for `up` — on a *cold* stack.** `EventMapper_Builder` creates its
resources *inside* `Pulumi.Output.apply`
([line 68](../../../reventless/core/src/components/EventMapper/EventMapper_Builder.res#L68)), and Pulumi
skips apply callbacks whose inputs are unknown during preview. That explains a long run of green
previews over a broken path. **Since tested and half-refuted:** against a *warm* stack the inputs are
known, the applies do run, and `preview` reproduces this failure in ~40s — which is the iteration loop
to use. That `.apply` is also why the error is garbled rather than pointed: a throw inside an apply
surfaces as an unresolved output, which `serializeEventMappersOutputs` then dereferences.

### 1a — the serializing call site: superseded by defect 3

`0aaef403a` removed the serialization error but did not create the Lambda. The builder it swapped in
is read-model-specific, so the side-effect handler fell through its `None` arm and nothing was built:
the crash became silence, the outcome this plan calls strictly worse. Fixed properly in defect 3
below. Kept as written at the time, because the instrumentation that found the call site is still the
useful part.

One instrumented run (a `console.error` with a stack trace in the emitted
`RuntimeEnvironment_Lambda.res.mjs`, reverted after) named it outright:

```
RuntimeEnvironment_Lambda.make("OrderNotificationsEventColl")
  ← core EventCollectorRuntime_Builder_PerEventCollector.forEventCollector
    ← core SideEffectHandler_Builder.res.mjs:39   (inside an Output.apply)
```

It is the **SideEffectHandler**, which vindicates the original call-site comment naming "a
side-effect-bearing Task" as the exposed surface. An intermediate guess that the EventMapper was the
culprit was wrong — the EventMapper appears in the *crash* (defect 1b) but not in the serialization.

The defect was one mis-wired module. Two AWS arms instantiate the same core builder:

```rescript
// SideEffectHandler_Single.res — correct
module EventCollectorRuntimeBuilder = SideEffectHandlerRuntime_Builder_Single       // AWS, compiled

// SideEffectHandler_PerSideEffectHandler.res — the bug
module EventCollectorRuntimeBuilder =
  ReventlessCore.EventCollectorRuntime_Builder_PerEventCollector.Make(…)           // core, serializing
```

AWS already has a compiled `EventCollectorRuntime_Builder_PerEventCollector` with the same interface
(`forEventCollector`, `finish`, both types, the channel); it is a plain module rather than a functor
because it is already bound to `DynamoDbStream` and the Lambda environment. Swapping that one module
reference removes the serialization error — verified against a from-scratch `up`, where
`Error serializing` and `captured 'Effect'` are both gone.

So no conversion work was needed: the compiled builder already existed, and only this arm had been
left pointing at core's.

**That last paragraph is wrong, and the way it is wrong is the lesson.** "The compiled builder already
existed with the same interface" was inferred from the interface alone. `forEventCollector` type-checks
for both, but AWS's `EventCollectorRuntime_Builder_PerEventCollector` dispatches on a
`readModelInfos` registry populated by `registerReadModel`, and builds `ReadModelEntryPoint.mjs`. A
side-effect handler is never in that registry. Matching module signatures said nothing about matching
behaviour, and the `up` that "verified" the fix only showed the *error* was gone.

## Defect 1b — the eventMappers export resolved the same record twice: FIXED

`serializeEventMappersOutputs` failed with `TypeError: m.apply is not a function`. Two commits were
needed, and the second one's diagnosis in `ab0c2f61e` was wrong about the mechanism — worth recording,
because the corrected mechanism is a general rule about this codebase's Pulumi bindings.

**The rule, measured directly** (a standalone script against the real `@pulumi/pulumi`):

| expression | nested Outputs inside the value |
|---|---|
| `output.apply(_ => record)` | **preserved** — still real Outputs |
| `pulumi.output(record)` | **deep-unwrapped** to plain values |
| `pulumi.all([...])` | **deep-unwrapped**, including each element's *contents* |

So `.apply` does not deep-unwrap, and a chain of `.apply` — which is all that stands between
`Aggregate_Builder` and `pluginOutputs.aggregates` — leaves `agg.eventMapper` a genuine Output.
Confirmed on a real preview by logging `Output.isOutput(agg.eventMapper)` for all three ordering
aggregates: `true`, `true`, `true`. The premise in `ab0c2f61e`'s message — "by then Pulumi has
already unwrapped it" — is therefore false at that call site.

`Output.all` is the one that unwraps, and `ab0c2f61e` introduced a call to it *before* resolving:
collecting `array<Output.t<option<EventMapper.outputs>>>` through `all` handed
`EventMapper.toResolvedOutputs` a record Pulumi had already resolved, and that function exists to
resolve an unresolved one. Hence the failure moving from the serializer's own `flatMap` down into
`toResolvedOutputs`. This file already knew the hazard — `serializePlainDictExport` carries the
comment "does NOT wrap the dict in `Pulumi.Output.make` (which deeply resolves nested Outputs and
breaks `toResolvedOutputs`)" — but the sibling serializer walked into it anyway.

**Fix:** resolve each `eventMapper` through *its own* Output first, carry absence as `None` through
the collection, and drop the absent ones after. Resolution happens once, at the depth where the
record is still unresolved. `Builder_Helpers.finishAggregates` keeps its `Output.all`-then-filter
shape — it only reads `eventCollector` for sequencing and never calls `toResolvedOutputs` — with a
comment saying why nothing in that block may.

**The type change in `ab0c2f61e` was still load-bearing, not just hygiene.** Rebuilding the
pre-refactor sources at `0aaef403a` and previewing reproduces the original `m.apply` throw at the
`Option.map(agg.eventMapper, …)` site, so `option<Pulumi.Output.t<_>>` genuinely did fail there while
`Pulumi.Output.t<option<_>>` genuinely does not. Why the optional-field form arrived unwrapped when
the always-Output form does not is *not* explained by anything measured here — recorded as unexplained
rather than papered over with a mechanism. It no longer blocks anything: the banned type is gone and
the field is now unconditionally an Output.

**Verified:** `preview` clean, then a real `up` on `ordering-aws/pr-verify` succeeded, and the
`eventMappers` stack export contains `OrderAggrEventMapper` with its EventCollector bound to the
`OrderAggrEventLog` DynamoDB stream. Build clean, zero warnings, 2295/2295.

**Why only ordering:** the field resolves to `None` unless the aggregate declares EventMappings, per
the gate above, so the same distribution table applies.

## Defect 3 — a side-effect handler's Lambda is never provisioned on AWS: FIXED

Found by reading the `up` log after 1b went green. The `up` reports success and the stack has six
Lambdas; none of them runs `OrderNotifications`' side effects. In the log:

```
WARN  no bundled info registered for OrderNotifications
      comp=EventCollectorRuntime_Builder_PerEventCollector
```

That is the `None` arm of the builder 1a swapped in, which logs and returns without creating anything.
Two independent gaps, either of which alone is enough:

**1. The per-side-effect arm is pointed at the read-model builder.** A side-effect-bearing Task reaches
`SideEffectHandler_PerSideEffectHandler` via `Task_Builder_PerBucket`. Its
`EventCollectorRuntime_Builder_PerEventCollector` keys on `readModelInfos` / `registerReadModel` and
bundles `ReadModelEntryPoint.mjs`. The right module is
[SideEffectHandlerRuntime_Builder_Single.res](../../../reventless/aws/src/adapter/Runtime/SideEffectHandlerRuntime_Builder_Single.res) —
`sideEffectInfos` / `registerSideEffectHandler`, bundling `SideEffectEntryPoint.mjs`. The arm also
never registers: `SideEffectHandler_Single` calls `registerSideEffectHandler` with module paths derived
from each `SideEffect`'s `moduleUrl`, and the `_Per` arm is a bare `include` of the core functor that
calls nothing.

**2. Nothing ever calls `finish()`, so even the correct arm builds no Lambda.** The
`AllSideEffectHandlers` Lambda is created *only* in `SideEffectHandlerRuntime_Builder_Single.finish()`.
`SideEffectHandler.T` has no `finish` member, `Task_Builder` has no finish seam for it, and there is no
call site anywhere in the repo. Every other component type has one (`ReadModel_Builder_Single`,
`Aggregate_Builder_*`, `AutomationSlice_Builder`, … all define `let finish = () => …Builder.finish()`);
the side-effect handler is the one that does not.

Consistent with both: **no deployed AWS stack has ever had a side-effect Lambda.** Neither
`online-shop-hybrid-ordering-aws/alpha` nor `online-shop-ordering-aws/alpha` contains
`AllSideEffectHandlers` or any per-handler equivalent. So this is not a regression in the ordinary
sense — it is a deploy path that was never finished, kept invisible because no deployed example had a
side-effect-bearing Task.

### The fix: shared Lambda, plus the missing finish seam

**Chosen shape:** one shared `AllSideEffectHandlers`, reusing the compiled `SideEffectEntryPoint` that
already exists and is unit-tested. `SideEffectHandler_PerSideEffectHandler` collapses to
`include SideEffectHandler_Single.Make()` and carries a comment recording both wrong wirings, because
the interesting part is *why* the second one type-checked. A real
`SideEffectHandlerRuntime_Builder_PerSideEffectHandler` remains the option if per-handler memory and
timeout tuning is ever wanted; the comment says where to hook it.

**The finish seam, and why it cannot be a plain call.** `finish` joins `SideEffectHandler.T`
(implemented in the core builder, the AWS arm, and `LocalSideEffectHandler` as a no-op). Calling it
straight after `make` would not work: registration into the runtime builder happens inside
`SideEffectHandler_Builder`'s `allCommandTopics->Output.apply`, so when `make` returns nothing has
registered yet, and a synchronous finish would build the shared Lambda from an empty — or worse,
partial — spec list. So `Task_Builder` registers each handler with a **gate**, its `operations` Output,
which the core builder sets at the end of `construct` after `forEventCollector` has run.
`Builder_Helpers.finishTasks` waits on all the gates and then runs the finish functions —
deliberately the same shape as `finishAggregates` next to it, which exists for the same reason.
`Plugin_Helpers.createTasks` calls it once every task is constructed.

**Verified on real AWS, not just by absence of error** — the check this defect existed for lack of:

```
Lambdas: … AllSideEffectHandlers …            (6 → 7, + role, role policy, event source mapping)
HANDLER_CONFIG: {"handlers":[{"sideEffectModules":
  ["…/src/Order/SideEffect/Order_EmailNotification.res.mjs"],
  "sourceUrn":"…table/OrderAggrEventLog-…/stream/…",
  "comp":"SideEffectHandler(OrderNotifications)","plugin":"Ordering"}]}
EventSourceMapping: Enabled, bound to the OrderAggrEventLog stream
```

The `no bundled info registered` warning is gone. Build clean, zero warnings, 2295/2295.

**Blast radius is one example.** `online-shop-aggregates/ordering` is the only package in the repo with
a side-effect-bearing Task, so `finishTasks` is a no-op for hybrid and dcb and no existing stack gains a
Lambda. That is also why this went unnoticed for so long.

**Also still live, one line above the fix site:** `Task_Builder_PerBucket` itself binds
`EventCollectorRuntimeBuilder` to core's serializing
`EventCollectorRuntime_Builder_PerEventCollector.Make(…)` — the same class of leak 1a chased, unaudited
as to whether it is reached. `RuntimeEnvironment_Lambda.res:21` names both this and the side-effect arm.
Carried to [Backlog/serializing-runtime-builder-audit.md](../Backlog/serializing-runtime-builder-audit.md).

## Defect 2 — AppSync 409 on data-source create: DOES NOT REPRODUCE

As originally observed in CI, creating catalog's data sources failed:

```
AppSync: CreateDataSource, StatusCode: 409,
ConcurrentModificationException: Schema is currently being altered, please wait until that
is complete.  provider=aws@7.19.0
```

### It does not reproduce, and "deterministic" was wrong

A from-scratch `catalog-aws/pr-verify` against the settled `platform-aws/pr-verify` **succeeds** — 155
resources created, exit 0. The three data sources the plan named created cleanly in under a second
each:

```
+ aws:appsync:DataSource Categories      created (0.81s)
+ aws:appsync:DataSource Products        created (0.83s)
+ aws:appsync:DataSource ProductDemands  created (1s)
```

The exception is still there, twice — but on **resolvers**, where `AppSync_Resolver_Retrying` already
absorbs it and the deploy carries on:

```
INFO attempt 1/8 failed, retrying in 2000ms: ConcurrentModificationException:
     Schema is currently being altered…    comp=AppSync_Resolver_Retrying
```

**Why data sources won here, and what that says about the fix.** Everything the plugin builds is
already gated on the schema push — `schemaPushed` is one of the inputs to the `Output.all6` that wraps
the whole plugin construction in `Plugin_Builder`, so nothing is created until
`subgraph schema is ACTIVE`. The log confirms the order: push at `02:30:30`, ACTIVE at `02:30:32`,
association, then the data sources. The resolver 409s land at `02:31:19` and `02:31:40` — **47 and 68
seconds after ACTIVE**. So the contention is not with the subgraph push at all; it is with the
*asynchronous merged-API merge* that keeps altering the schema long after the push reports done. Data
sources are created in a narrow window right after the gate and usually miss it; resolvers are created
deep inside it and routinely hit it.

**That kills option 2.** `dependsOn` chaining assumed data sources contend with each other. They do
not — they contend with an async merge, and the ordering gate that *would* help already exists. There is
nothing left to order against.

**And there is no free fix.** `aws:maxRetries` cannot help: the SDK models the error as
`$fault: "client"` with no retryable marker (`@aws-sdk/client-appsync`), so neither the SDK nor the
Terraform provider beneath `aws:appsync:DataSource` will retry it. That is precisely why
`AppSync_Resolver_Retrying` hand-rolls its own loop, as its comment says.

**So option 1 is the only real answer, and it is now a hardening rather than a blocker.** If done,
extract `runWithRaceRetry` and `isSchemaAlteringError` from `AppSync_Resolver_Retrying` into a shared
module first and build a thin `AppSync_DataSource_Retrying` on it — the resolver provider's 653 lines
are mostly its six-field SDK surface, not the retry logic, and a third copy of the retry loop would be
the wrong shape. Roughly 10 `DataSource.make` call sites to rewire.

**Left undone deliberately.** The race is real and recorded, but it did not reproduce, the create path
is no longer blocked by it, and speculatively adding a third dynamic provider is a poor trade against
evidence this thin. The trigger to do it: a CI run failing this way again — where the platform stack is
created in the same pipeline window, which is the condition the original two failures shared and this
reproduction did not.

## Sequencing

**Nothing is blocking the create path.** 1b and 3 are fixed and deploy-verified; 2 did not reproduce.

Two follow-ups carried to the backlog rather than left buried here:

- [Backlog/appsync-datasource-retrying.md](../Backlog/appsync-datasource-retrying.md) — defect 2's
  hardening, with its fix shape settled and its trigger named.
- [Backlog/serializing-runtime-builder-audit.md](../Backlog/serializing-runtime-builder-audit.md) —
  `Task_Builder_PerBucket`'s own binding to core's serializing builder, plus the other core builders
  still calling `RuntimeEnvironment.make`. Both fail silently, which is why they are worth an audit
  before they are worth a bug report.

**Verification, corrected.** `preview` against a warm `pr-verify` stack reproduces the export-side
failures in ~40s with no AWS writes — that is the iteration loop, and it is an order of magnitude
better than what this plan previously assumed. Then one `up` to confirm, plus `pulumi stack output` to
check the export actually carries content. Set `REVENTLESS_LAYER_ARN` from
`aws ssm get-parameter --name /reventless/layer-arn/alpha --region eu-west-1` first, or the `up` strips
the Lambda layer from every function. Note `pulumi stack rm` deletes the tracked `Pulumi.pr-verify.yaml`
— restore with `git checkout` before re-creating.

**On green deploys as evidence.** Defect 3 exists because `0aaef403a` verified a fix by observing that
an *error message* had disappeared. It had, and nothing was built in its place. Two checks would have
caught it, and both are cheap: diff the Lambda list before and after
(`pulumi stack export | … type == "aws:lambda/function:Function"`), and read the `up` log for `WARN`
lines — the builder announced its own no-op on every run. For this framework specifically, "the deploy
is green" is weak evidence at best: builders skip silently when a registry lookup misses, so absence of
error and presence of resource are genuinely separate questions.

**On peeling.** 1b moved twice under individually-correct fixes and the component was mis-identified
twice. What actually settled it was measurement, not more reading: a 20-line script against the real
`@pulumi/pulumi` established which combinators deep-unwrap, and one `Output.isOutput` log line at the
crash site disproved the mechanism the previous commit message asserted. When a bug is about *runtime*
identity — is this value an Output or not — static tracing will keep producing plausible wrong answers.
