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

**Not yet pinned:** which component in `ordering` reaches it. `AllReadModels` updates successfully in
the same run, so the failing Lambda is a different, newly-created one — the plausible candidates are
the side-effect-bearing Task (`Task/OrderNotifications.res`) and the side effect
(`Order/SideEffect/Order_EmailNotification.res`), which is consistent with the call-site comment
naming "a side-effect-bearing Task" as the exposed surface, and with `online-shop-hybrid` having no
equivalent component. Confirm this before converting anything — the conversion is per-builder, and
converting the wrong one fixes nothing.

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
