# Plan: the create path for a new plugin stack

**Date:** 2026-07-29
**Status:** Two defects root-caused with live evidence, neither fixed. Both block creating a plugin
stack from scratch; neither affects an existing one.
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

### 1a — the serializing call site: FIXED

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

## Defect 1b — `option<Pulumi.Output.t<_>>` on `Aggregate.outputs.eventMapper`

With 1a fixed, the same `up` still fails with `TypeError: m.apply is not a function` — so this was
never a downstream symptom of the serialization failure. It is an independent bug the first one was
masking.

[Plugin_Helpers.res:1248](../../reventless/core/src/plugin/component/Plugin_Helpers.res#L1248)
resolves `pluginOutputs.aggregates` with `Output.flatMap`, then calls `Output.flatMap` again on
`agg.eventMapper`'s inner value. Pulumi's `apply` **deeply unwraps nested outputs**, so by then that
value is the resolved record rather than an Output — and `flatMap` is `map` over `.apply`, which a
plain record does not have.

The sharpest evidence that the *type* is the problem: [Aggregate.res:58](../../reventless/core/src/components/Aggregate/Aggregate.res#L58)
performs the identical `Output.flatMap` on `outputs.eventMapper` and is correct, because it is not
nested inside an enclosing apply. One expression, one type, two runtime natures decided purely by
lexical position. That is precisely why `option<Pulumi.Output.t<'a>>` is banned in this repo's
conventions; this is that pattern in the wild.

**Fix:** move the field to the allowed shape — `Pulumi.Output.t<option<EventMapper.outputs>>`, output
outside and option inside. Four sites: `Aggregate_Builder` (which already builds it inside an apply,
so the option is available at the right depth), `Aggregate.res`, `Builder_Helpers`, and the
serializer. Do **not** paper over it with a cast at the serializer — a cast is correct only at that
one call depth, which restates the trap rather than removing it.

**Why only ordering:** the field is absent unless the aggregate declares EventMappings, per the gate
above, so the same distribution table applies.

**Fix:** the documented one — an `_Ops.res` split plus `buildCodeArchive`, as already done for the
presign service and the geocoder. `make` cannot simply be deleted: `Runtime.Environment` requires an
`environmentMaker`, and the in-memory platform implements it for real via `LocalRuntimeEnvironment`.

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

Defect 2 blocks catalog; defect 1 blocks ordering. They are independent, and either can go first.
Defect 1 wants its component pinned before any code changes; defect 2 wants a decision between the
two shapes above. Both should be verified the same way these were found — a `pr-verify` deploy from
scratch, since neither reproduces on an existing stack.
