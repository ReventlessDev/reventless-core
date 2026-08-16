# Plan: stop the Lambda environment growing with the plugin

**Status.** Not started. The two commits that prompted this —
`3cda4cb78` (DCB slice registry → `sliceModules.json`) and the EventCollector
map move — are relocations that bought headroom, not fixes. This plan is about
not needing a third one.

## The problem

AWS caps a Lambda's entire environment at 4096 bytes and enforces it on
`UpdateFunctionConfiguration`, in the middle of a `pulumi up`. The error names a
byte count and not the field that grew:

```
InvalidParameterValueException: Lambda was unable to configure your environment
variables because the environment variables you have provided exceeded the 4KB
limit. Measured size: 4451 bytes
```

By the time it fires, the surrounding resources have already moved, so the stack
is left half-updated and the next run opens with `recovered raw state does not
byte-for-byte match the original raw state`.

This has now happened three times, each time to a different Lambda, each time
because a term that scales with the size of the plugin was being carried in the
environment:

| When | Lambda | The term that grew | Fix applied |
| --- | --- | --- | --- |
| earlier | `<Plugin>PluginEventColl` | `pluginDefinition` inline in `HANDLER_CONFIG` | → `pluginDefinition.json` asset |
| 2026-08-16 | `CatalogDcbCmdHandler` | one `{spec, behavior}` pair per StateChangeSlice (4451 B) | → `sliceModules.json` asset |
| 2026-08-16 | `CatalogPluginEventColl` | `publishToAggregates` map + the `PTA_*` vars it names (4477 B) | map → `queueUrls.json`; **vars still in the environment** |

All three were triggered by ordinary domain work — the third by adding
Archive/Unarchive slices to the example shop. Nothing about those commits was
unusual; the plugin simply got bigger, which is what plugins do.

## Why it keeps recurring

Three things compound, and only the first has been addressed:

1. **Nothing enforced the ceiling.** It was discovered by AWS, mid-deploy.
   `Util_LambdaEnvBudget` now checks it at deploy time, but see step 4 — as
   shipped it warns in the case that matters most.

2. **The environment is being used as a transport for deploy-time data.** None
   of what overflowed is secret or runtime-variable. It is a registry computed
   during `pulumi up` and read once at cold start. The environment is simply
   where it landed, and it is the one channel in the system with a hard size
   limit. The code archive has no such limit and is already the established
   alternative (`Util_Bundle.buildCodeArchive ~extraStringAssets`).

3. **Each fix moved one term.** Moving `pluginDefinition` did not stop the slice
   registry from growing into the same space; moving the slice registry did not
   stop the queue-URL vars. Every relocation resets the clock and leaves the next
   term to find the wall on its own.

The current headroom makes the point. After the map move the catalog
EventCollector sits at roughly 3681 bytes against a 4096 limit — about 415 bytes,
and the remaining `PTA_*` vars cost ~120 bytes per slice. That is three or four
more slices before the third fix needs a fourth.

## The invariant worth establishing

> A Lambda's environment carries only terms of fixed size. Anything whose size
> depends on how many components the plugin has travels in the code archive.

This is a property the build can check, which is what makes it different from a
convention. It also matches where the codebase has already been heading — three
assets (`pluginDefinition.json`, `uiFragments.json`, `sliceModules.json`) exist
precisely because their contents outgrew the environment.

## The blocking unknown, and what the code actually says

The obvious application of the invariant — put the resolved queue URLs in
`queueUrls.json` and delete the `PTA_*`/`PRM_*` vars — was proposed and then
withdrawn, on the strength of this note in `PluginRuntime_Builder.res`:

> the dict is declared as `dict<Output<string>>` but `Plugin_Builder.res` also
> writes `Output<publishJsons>` (function values) under DCB slice names — the
> type is a polite lie […] `Pulumi.Output.all` is deliberately NOT used here: the
> DCB slice's URL is an `.apply`-lifted Output, and `Pulumi.Output.all`
> mis-resolves such lifted Outputs to the `BS_PRIVATE_NESTED_SOME_NONE` sentinel.

Reading the population path suggests that note conflates **two different
variables that share a name**, and that only one of its two hazards applies to
the runtime builder:

- The dict holding function values is the one at `Plugin_Builder.res:356`
  (`publishToAggregates->Dict.set(Sc.Spec.name, slicePublishJsons)`), used for
  extension dispatch.
- The dict that reaches `PluginRuntime_Builder` is a *different* one:
  `context.publishToAggregates` ← `Plugin_Helpers.mergedAggregateUrls` ←
  `Plugin_Builder.aggregateQueueUrls`, which is populated only with `r.id` and
  `dcbResult.dcbCommandTopicQueueUrl` — genuine `Output<string>`.
- `Pulumi.Output.allDict` is already applied to the *function-valued* dict, at
  `Plugin_Builder.res:645` and `Platform_Admin.res:374`, and those deploys work.

If that reading holds, the function-value hazard does not apply to the dict in
question, and `allDict` (which delegates to Pulumi's own `all`, rather than
mapping `.apply` over the values) is the safe primitive.

The second hazard is separate and is **not** dismissed by any of the above:
`dcbCommandTopicQueueUrl` is genuinely `.apply`-lifted, and there is independent
evidence in this repo that `all()` flattens contents in a way that breaks lifted
Outputs. Step 1 exists to settle that, because everything downstream depends on
it and no amount of reading will.

## Steps

**1 — Settle the Output question (spike, no production change).**
On a branch, resolve `context.publishToAggregates` with `Output.allDict` inside
`PluginRuntime_Builder` and write the result to a throwaway asset. Run
`pulumi preview` against the hybrid catalog stack, which has both aggregates and
DCB slices, and check whether the DCB slice entries resolve to real URLs or to
the sentinel. The answer decides step 2. Record it in this file either way —
a negative result is worth as much as a positive one and is the reason the note
above exists.

*If the sentinel appears*: the lifted Output is the real constraint, and the fix
is either an `Output.all` binding that preserves lifted values, or having
`Dcb_Builder` publish a non-lifted URL Output. Both are larger than this plan and
should get their own; the invariant then applies to everything except the queue
URLs, and step 4's budget has to leave room for them.

**2 — Move the queue URLs into the archive.**
Given a clean spike: `queueUrls.json` carries `name → URL` instead of
`name → env-var name`; `PluginRuntime_Builder` stops emitting `PTA_*`/`PRM_*`;
`EventCollectorEntryPoint_Ops.loadQueueUrlNames` becomes a URL loader and the
env lookup in `buildPublishToAggregates` / `extensionPublishDicts` goes away.
This removes ~1800 bytes from the catalog EventCollector and, more to the point,
removes the last term in that Lambda that scales with the plugin.

**3 — Audit the remaining Lambdas.**
The three incidents were found by deploying. Enumerate every `makeFromCodeAsset`
call site, and for each one list which environment terms scale with plugin size.
`CatalogProductsExtPointCmdHandler` and the aggregate command handlers have not
been measured and are the obvious next candidates. Expected output: a short table
in this file, and an issue per Lambda that violates the invariant.

**4 — Make the invariant enforceable.**
`Util_LambdaEnvBudget` currently throws only when the *exact* portion exceeds
4096, and warns when the estimate does. That is the right call while queue URLs
are unresolved Outputs of unknown length, and the wrong one afterwards. Once
step 2 lands there are no unresolved values left in these environments, so:
lower the budget to something well under the limit (~2048, since nothing should
be near it any more), make every overage throw, and delete the allowance. A test
that asserts a representative `HANDLER_CONFIG` stays under budget will then fail
in CI when someone adds a scaling term, instead of on a deploy.

**5 — Write down the rule.**
One paragraph in `docs/guides/lambda-deployment.md`: what the environment is for,
what the archive is for, and the fact that an asset costs a `readFileSync` at
cold start and nothing else. The three assets that already exist are the worked
examples.

## How we would know it worked

The measure is not a byte count, it is that adding components stops being able to
break a deploy. Concretely: after step 2, adding ten slices to the hybrid catalog
should move the EventCollector and DCB handler environments by zero bytes. That
is a test worth writing at step 4 — synthesise a plugin context with 10 and with
100 targets, and assert the serialized `HANDLER_CONFIG` is byte-identical.

## What this deliberately does not do

- **It does not make the Lambda discover queue URLs at runtime.** Deriving them
  by convention fails on the Pulumi-generated name suffix, and `GetQueueUrl` or
  `ListQueues` at cold start buys an API call, IAM surface, and a new failure
  mode to replace a problem that a file in the archive solves outright.
- **It does not touch the `.apply`-lifted Output design in `Dcb_Builder`**
  unless step 1 forces it. If the spike comes back clean, that lifting is
  irrelevant to this problem and should be left alone.
- **It does not need to address the stale-state error.** `recovered raw state
  does not byte-for-byte match the original raw state` comes from the AWS
  provider's bridge layer and is emitted only on a resource whose update has
  already failed — 1.6 ms after the 4KB rejection, never on its own. It is a
  consequence, so fixing the cause stops it.

  It leaves nothing to repair. Checked on `CatalogPluginEventColl` after the
  failed run: recorded state and the live function agree at 3559 environment
  bytes, `LastModified` still predates the failed deploys, and the stack carries
  no pending operations. AWS rejected `UpdateFunctionConfiguration` during
  validation, so the resource was never mutated. `CatalogDcbCmdHandler` carried
  the same error one run and updated cleanly the next, which says the same thing
  from the other side. No `pulumi refresh` pass is owed.
