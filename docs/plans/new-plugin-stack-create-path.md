# Plan: the create path for a new plugin stack

**Date:** 2026-07-29, updated 2026-07-30
**Status:** **1b fixed and deploy-verified** — `ordering-aws` now completes `up` and exports its
event mapper. **1a is not fixed after all**: it replaced a crash with a silently missing Lambda, and
the deeper truth is that a side-effect handler's Lambda has *never* been provisioned on AWS by any
path — reopened below as **defect 3**. **2 untouched**. None of this affects an existing stack.

**Verification loop is much cheaper than recorded.** `pulumi preview` against a warm `pr-verify`
stack reproduces the export-serialization failures in ~40s with no AWS writes; the plan previously
assumed only a full `up` would do. Use preview to iterate, one `up` to confirm. The earlier note that
previews skip `EventMapper_Builder`'s `.apply` holds only for a *cold* stack — once the inputs are
known, the apply runs.
**Found by:** the first-ever deploy of `online-shop-aggregates`, standing up the `PlatformOwned`
serving arm — see [declared-object-stores-without-host-ui-bundle.md](./declared-object-stores-without-host-ui-bundle.md).

## Why these were invisible

Every deployed plugin stack was created long ago and is only ever *updated*. Nothing had created one
from scratch in a long time, so the create path had no coverage of any kind — not CI, not a preview,
not a deploy. Two of the four defects that path contained have already been fixed (a missing
generated deploy root, and SDK command names that named the Pulumi resource rather than the AppSync
operation, `777c8ff7e`). These are the remaining two.

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

**This is already documented at the call site.** [RuntimeEnvironment_Lambda.res:25-33](../../reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res#L25)
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

[Aggregate_Builder.res:44](../../reventless/core/src/components/Aggregate/Aggregate_Builder.res#L44)
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

**A preview cannot substitute for `up` here** (untested but worth checking before relying on one):
`EventMapper_Builder` creates its resources *inside* `Pulumi.Output.apply`
([line 68](../../reventless/core/src/components/EventMapper/EventMapper_Builder.res#L68)), and Pulumi
skips apply callbacks whose inputs are unknown during preview. If that holds, no preview of any
plugin stack has ever constructed this component, which would explain a decade of green previews over
a broken path. That `.apply` is also why the error is garbled rather than pointed: a throw inside an
apply surfaces as an unresolved output, which `serializeEventMappersOutputs` then dereferences.

### 1a — the serializing call site: NOT FIXED (see defect 3)

`0aaef403a` removed the serialization error but did not create the Lambda. The builder it swapped in
is read-model-specific, so the side-effect handler falls through its `None` arm and nothing is built.
The crash became silence — the outcome this plan calls strictly worse. Kept below as written at the
time, because the instrumentation that found the call site is still the useful part.

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

## Defect 3 — a side-effect handler's Lambda is never provisioned on AWS

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
[SideEffectHandlerRuntime_Builder_Single.res](../../reventless/aws/src/adapter/Runtime/SideEffectHandlerRuntime_Builder_Single.res) —
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

**Decision needed before implementing** — the two gaps have one shared question:

1. **Shared Lambda.** Point the `_Per` arm at `SideEffectHandlerRuntime_Builder_Single`, register like
   `_Single` does, and add the missing `finish` seam. Smallest change, reuses the compiled entry point
   that already exists and is unit-tested (`SideEffectEntryPoint_OpsTest`). Cost: "per side effect
   handler" then means one shared `AllSideEffectHandlers`, so the module name stops describing the
   topology and the two arms become the same thing — which argues for collapsing them.
2. **A real per-handler builder.** Write `SideEffectHandlerRuntime_Builder_PerSideEffectHandler`,
   mirroring the read-model per-collector builder but over `sideEffectInfos` and
   `SideEffectEntryPoint.mjs`. Keeps the strategy distinction honest and gives per-handler memory and
   timeout tuning; costs a new module and a second registry to keep in step.

Either way the `finish` seam is required, and that part is not optional.

**Also still live, one line above the fix site:** `Task_Builder_PerBucket` itself binds
`EventCollectorRuntimeBuilder` to core's serializing
`EventCollectorRuntime_Builder_PerEventCollector.Make(…)` — the same class of leak 1a chased, unaudited
as to whether it is reached. `RuntimeEnvironment_Lambda.res:21` names both this and the side-effect arm.

## Defect 2 — AppSync 409 on data-source create

Creating catalog's data sources fails:

```
AppSync: CreateDataSource, StatusCode: 409,
ConcurrentModificationException: Schema is currently being altered, please wait until that
is complete.  provider=aws@7.19.0
```

**Deterministic, not a race between stacks.** A re-run reproduced it identically, and the log shows
`Categories`, `ProductDemands` and `Products` all failing within the same second — one stack's own
data sources being created in parallel while the schema it just created is still settling. The
initial reading (two plugin jobs colliding) was wrong; a second dispatch ruled it out.

**Fix, two candidate shapes:**

1. **A retrying dynamic provider**, mirroring `AppSync_Resolver_Retrying` (653 lines) and
   `AppSync_SourceApiAssociation_Retrying` (471). Consistent with how the codebase already handles
   AppSync's 409s, and the precedent is close enough to follow rather than invent. Cost: a third
   sizeable provider, plus rewiring ~10 `DataSource.make` call sites.
2. **Serialize creation** so data sources do not contend — `dependsOn` chaining. Much smaller, but
   the data sources belong to *different components*, so chaining them couples components at deploy
   time for a reason that is not about their domain relationship. That is the kind of coupling the
   split-stack design exists to avoid, so it needs a decision rather than a patch.

Option 1 is the consistent answer; option 2 is the cheap one. Neither is a small edit, which is why
this is recorded rather than done.

## Sequencing

**Ordering now deploys.** 1b is closed. What remains: **2 blocks catalog** (a hard failure), and **3
blocks nothing visibly** — the deploy is green and the side effects simply never run. Independent of
each other; 2 is the one that stops a stack from being created.

Both need a decision before code: 2 between the retrying provider and `dependsOn` chaining, 3 between a
shared and a per-handler Lambda. Neither reproduces on an existing stack.

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
