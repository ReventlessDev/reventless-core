# Plan: Convert the last CallbackFunction Lambda path to a compiled entry point

> **Do not start at step 1 — the approach below is probably over-built.**
> A later pass (same day) found that a `makeFromCodeAsset` implementation of the
> same `SideEffectHandler.T` interface **already exists** (`SideEffectHandler_Single`,
> canonicalised as `components/SideEffectHandler.res`, backed by
> `SideEffectHandlerRuntime_Builder_Single`), which would make the new entry point
> in steps 1–2 unnecessary. It also found that the wider subsystem is unwired on
> AWS regardless. See **§ Late finding** at the bottom before acting on any of this.

**Status:** Proposed (2026-07-27). Found while auditing the open question left by
[done/entry-point-rescript-conversion.md](done/entry-point-rescript-conversion.md)
§5 — "verify `RuntimeEnvironment_Lambda.res`'s `CallbackFunction` path is not the
same pattern". It is reachable, but the failure mode is worse than that question
assumed, and it was knowingly deferred twice before.

## Prior art — this is a deferral, not a discovery

Two completed plans already knew about this path:

- [done/bundled-handler-cleanup.md](done/bundled-handler-cleanup.md) §4a listed
  twelve component builders under "Delete non-bundled component builders — these
  files use non-bundled runtime builders that create Lambdas via
  `CallbackFunction.make` → fails with Effect-TS". `SideEffectHandler_PerSideEffectHandler.res`
  and `Task_Builder_PerBucket.res` are both on that list. The step was not
  completed for them.
- [done/complete-bundled-migration.md](done/complete-bundled-migration.md) §7
  closed its blocker with: "The non-bundled path **remains broken** but is no
  longer used by bundled plugins." That sentence is the deferral this plan closes.

**That §4a inventory is now stale** — worth not trusting it wholesale. Of the
twelve files listed, `SideEffectHandlerWithQueue_Single.res` and
`SideEffectHandlerWithQueue_PerSideEffectHandler.res` are gone, and the rest
except the three named below have since been repointed at AWS-local runtime
builders that use `makeFromCodeAsset` (`SideEffectHandler_Single` →
`SideEffectHandlerRuntime_Builder_Single`, `ReadModel_Builder_PerReadModel` →
the AWS `EventCollectorRuntime_Builder_PerEventCollector`, and so on).
`TaskRuntime_Builder_PerBucket` itself was converted too. The authoritative test
is not the table but `grep -rn "CallbackFunction.make" --include=*.res reventless/aws/src`,
which today returns exactly one hit.

## Problem

`RuntimeEnvironment_Lambda.make`
([RuntimeEnvironment_Lambda.res](../../reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res))
is the only remaining `Lambda.CallbackFunction.make` in `reventless/aws/src`. It
was commented as dead — "Not called at runtime; all Lambda deployments now use
makeFromCodeAsset" — and the entry-point conversion plan closed on that basis.
The comment was wrong.

Three AWS component builders instantiate the core per-collector functor over this
module:

- [ForeignReadModel_Builder.res:3](../../reventless/aws/src/components/ForeignReadModel_Builder.res#L3)
- [SideEffectHandler_PerSideEffectHandler.res:3](../../reventless/aws/src/components/SideEffectHandler_PerSideEffectHandler.res#L3)
- [Task_Builder_PerBucket.res:3](../../reventless/aws/src/components/Task_Builder_PerBucket.res#L3)

`ReventlessCore.EventCollectorRuntime_Builder_PerEventCollector.forEventCollector`
([EventCollectorRuntime_Builder_PerEventCollector.res:29](../../reventless/core/src/adapter/Runtime/EventCollectorRuntime_Builder_PerEventCollector.res#L29))
calls `RuntimeEnvironment.make`, so any of those three reaching `forEventCollector`
provisions a serialized-closure Lambda.

### The live route

A Task whose spec returns `Task.sideEffects`:

1. `Platform.Task.Make` → `Task_Builder_PerBucket.Make` → `ReventlessCore.Task_Builder.Make`.
2. `Task_Builder.construct` sees `config.sideEffects` as `Some(_)` and calls
   `SpecificSideEffectHandler.make`
   ([Task_Builder.res:82-94](../../reventless/core/src/components/Task/Task_Builder.res#L82-L94)).
3. `SideEffectHandler_Builder.construct` calls `EventCollectorRuntimeBuilder.forEventCollector`
   ([SideEffectHandler_Builder.res:55](../../reventless/core/src/components/SideEffectHandler/SideEffectHandler_Builder.res#L55)).
4. That lands in `RuntimeEnvironment_Lambda.make` → `Lambda.CallbackFunction.make`.

A shipped example takes this route:
[OrderNotifications.res](../../examples/online-shop-aggregates/ordering/src/Task/OrderNotifications.res)
declares `Task.sideEffects: [module(Order_EmailNotification)]`, and
`examples/online-shop-aggregates/ordering-aws/src/Main.res` deploys that plugin.

### Why it matters — the primary failure is at deploy time, and it is silent

The obvious risk is the runtime one: a `CallbackFunction` Lambda serializes its
closure and resolves `@aws-sdk` against whatever the layer and the Node runtime
each supply, which is the cold-start SDK-skew 502 documented for the presign and
geocoder handlers. That risk is real here, but it is the *second* one.

The first is worse. Pulumi's closure walker **fails outright on Effect-TS**, and
the failure is swallowed: the Lambda is never created and the deploy reports
success. `done/complete-bundled-migration.md` records this from an actual
`ordering-aws` deploy that produced only four Lambda functions, with the DCB
EventCollector among the silently missing ones. So the expected symptom of a
side-effect-bearing Task on AWS is not a broken side effect — it is **no
side-effect Lambda at all, and no error saying so**.

That reframes step 5 of the approach below: the validation is "does the Lambda
exist", before "does it run".

### Why it hasn't been observed

CI deploys `online-shop-hybrid` to alpha, and that example's only Task
(`catalog/src/Task/ImportProducts.res`) declares no side effects — its
`sideEffectHandler` is `None`, so step 2 above never fires. The alpha stack has
no CallbackFunction Lambdas from the current generation.

Two do exist from a retired `dev` stack: `ProfilePictureTaskEventColl-c24b540`
and `ProfilePictureTaskBucket-d2d3691` (handler `__index.handler`, layer
`reventless-aws:24`, `Environment=dev`, last modified 2025-08-28). Note what
they prove: closure serialization **succeeded** for those two in 2025-08. So the
Effect-TS walker failure is not unconditional — it depends on what the specific
handler closes over, and a side-effect collector closing over
`SideEffectHandler_Callback` is not the same closure as those. Whether
`ordering-aws` today loses its Lambda or merely gets a fragile one is therefore
unknown, and worth establishing by deploying it before designing the fix.

## Constraint: `make` cannot just be deleted

`Runtime.Environment` requires `environmentMaker`
([Runtime.res:137-149](../../reventless/core/src/adapter/Runtime/Runtime.res#L137-L149)),
and the in-memory platform implements it for real —
`LocalRuntimeEnvironment.make` registers the handler in a `Deferred` that
consumers await. Local also instantiates `PluginRuntime_Builder_Micro`,
`ExtensionPointRuntime_Builder_PerExtensionPoint` and
`TaskRuntime_Builder_PerBucket` over it. So the seam stays; only the AWS
implementation of it needs to go.

Replacing the AWS body with `failwith` is not acceptable either — it would turn
`ordering-aws` deploys from "provisions a fragile Lambda" into "fails to deploy".

## Approach

Give the three builders a compiled entry point, the same shape as the
conversions in the entry-point plan, then remove `make`'s body.

0. **Establish the actual symptom first.** Deploy
   `examples/online-shop-aggregates/ordering-aws` as it stands and count the
   Lambdas. Either the `OrderNotifications` side-effect collector is missing
   (closure walker failed silently — the `complete-bundled-migration.md` symptom)
   or it exists as an `__index.handler` function (fragile but present). This is
   cheap, it decides how urgent the rest is, and it gives the before-picture for
   step 5.
1. **Entry point + `_Ops` split.** Add a `SideEffectCollectorEntryPoint.res` with
   a runtime-pure `_Ops` core: read `HANDLER_CONFIG` for the side-effect module
   paths and target command topics, decode the collector event, dispatch through
   `SideEffectHandler_Callback`. Verify the compiled import graph is `@pulumi`-free.
2. **AWS per-collector runtime builder.** The existing AWS
   `EventCollectorRuntime_Builder_PerEventCollector`
   ([EventCollectorRuntime_Builder_PerEventCollector.res](../../reventless/aws/src/adapter/Runtime/EventCollectorRuntime_Builder_PerEventCollector.res))
   is not a drop-in: it is ReadModel-specific (keys off `readModelInfos` by parent
   name) and hardwired to `EventCollectorChannel.DynamoDbStream`. Either generalise
   it or add a sibling that provisions via `makeFromCodeAsset` + `buildCodeArchive`.
3. **Repoint the three builders** off `ReventlessCore.EventCollectorRuntime_Builder_PerEventCollector.Make`.
4. **Empty out `RuntimeEnvironment_Lambda.make`** — once nothing on AWS calls it,
   the body, the `Obj.magic` at the `CallbackFunction.t` → `Function.t` coercion,
   and the last `CallbackFunction.make` all go. The signature stays for the
   module type.
5. **Validate on AWS** by deploying `examples/online-shop-aggregates/ordering-aws`
   and exercising `OrderNotifications` — the one path that actually runs this code.

## Verification

- `grep -rn "CallbackFunction.make" --include=*.res reventless/aws/src` returns nothing.
- Import-graph walk over the new entry point is `@pulumi`-free.
- `ordering-aws`'s side-effect collector Lambda **exists** (the step-0 baseline is
  what this is measured against) and carries a layer, `NODE_OPTIONS`, and
  `ESM_FALLBACK_DIRS` — i.e. `makeFromCodeAsset`, not `__index.handler`.
- Root build zero-warning; monorepo jest green.

## Late finding — the approach above solves the wrong problem

Three things surfaced after the approach was drafted. Together they say: do not
build a new entry point.

**1. Two of the three builders are simply dead.**
`ForeignReadModel_Builder` has zero references anywhere in `reventless/` or
`examples/`. And core `Task_Builder` declares `EventCollectorRuntimeBuilder` as a
functor parameter ([Task_Builder.res:22](../../reventless/core/src/components/Task/Task_Builder.res#L22))
that its body never uses — so the core per-collector instantiation in
`Task_Builder_PerBucket` exists only to satisfy an unused parameter. That leaves
`SideEffectHandler_PerSideEffectHandler` as the sole real consumer, and it becomes
unreferenced the moment `Task_Builder_PerBucket`'s `SideEffectHandler` alias is
repointed.

**2. The replacement already exists.** `SideEffectHandler_Single`
([SideEffectHandler_Single.res](../../reventless/aws/src/components/SideEffectHandler_Single.res))
implements the same `SideEffectHandler.T` with the same `make` arguments, over
`SideEffectHandlerRuntime_Builder_Single` (a `makeFromCodeAsset` builder that
registers into a shared "AllSideEffectHandlers" Lambda). `components/SideEffectHandler.res`
is already `include SideEffectHandler_Single`, i.e. it is the canonical choice.
The whole conversion may reduce to changing one alias in
[Task_Builder_PerBucket.res:9](../../reventless/aws/src/components/Task_Builder_PerBucket.res#L9)
and deleting two files. Note the semantic difference to confirm: one shared
Lambda for all side-effect handlers rather than one per handler.

**3. But neither implementation is wired, so the feature does not work on AWS
either way.** `SideEffectHandler` / `SideEffectHandler_Single` has no consumers —
nothing constructs it. And `SideEffectHandlerRuntime_Builder_Single.finish()`,
which is what actually builds the shared Lambda, is never called: the only
`finish()` calls in `Platform.res` are `AutomationSliceRuntime_Builder_Single.finish()`
(line 698) and `StateTopic_AppSync.finish()` (line 780). So the CallbackFunction
route leads into a subsystem with no wired exit, and converting it would produce
a correctly-built Lambda that still nothing assembles.

### The question this plan should have asked

Not "convert or delete this path", but **"are Task side effects a supported AWS
feature?"**

- **If yes** — the work is wiring `SideEffectHandler_Single` end to end
  (construct it from `Task_Builder_PerBucket`, call `finish()` from `Platform.res`
  alongside the AutomationSlice one), and the CallbackFunction path dies as a side
  effect of that. No new entry point.
- **If no** — delete both variants and make `Task.sideEffects` a compile-time
  error on AWS, then fix or retire
  `examples/online-shop-aggregates/ordering/src/Task/OrderNotifications.res`,
  which is currently the only thing declaring it.

Step 0 (deploy `ordering-aws`, count Lambdas) is still worth doing first and is
unaffected by this finding — it establishes what the current behaviour actually
is, which neither branch above can be planned against without.

## Housekeeping while here

The orphaned `dev`-stack Lambdas (`ProfilePictureTask*`, layer
`reventless-aws:24`) and their roles are dead resources in `eu-west-1` from a
stack that no longer exists. Worth removing separately from this plan.
