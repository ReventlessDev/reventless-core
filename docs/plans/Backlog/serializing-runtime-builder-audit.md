# Plan (Backlog): audit the remaining serializing runtime builders

**Status:** Backlog (not started).

**Origin:** [done/new-plugin-stack-create-path.md](../done/new-plugin-stack-create-path.md) defects 1 and 3.

**Why this is worth doing even though nothing is failing:** the failure mode is *silence*. Pulumi's
closure walker cannot serialize a handler that closes over Effect, and when it fails the Lambda is
simply never created while the deploy still reports success. The create path hid a missing side-effect
handler Lambda this way for a long time, and it only surfaced because an unrelated crash happened to
sit downstream of it.

---

## What to audit

**1. `Task_Builder_PerBucket` binds its own serializing builder.** One line above the arm fixed in
defect 3, [Task_Builder_PerBucket.res](../../../reventless/aws/src/components/Task_Builder_PerBucket.res)
still does:

```rescript
module EventCollectorRuntimeBuilder = ReventlessCore.EventCollectorRuntime_Builder_PerEventCollector.Make(
  RuntimeEnvironment,   // = RuntimeEnvironment.Lambda → CallbackFunction → serialized closure
  EventCollectorChannel,
)
```

Unaudited as to whether it is reached at deploy time. If it is, it has the same defect the side-effect
arm had.

**2. Core builders still calling `RuntimeEnvironment.make`** (the `CallbackFunction` path):
`PluginRuntime_Builder_Micro`, `PluginRuntime_Builder_Single`, `AggregateRuntime_Builder_Micro`,
`AggregateRuntime_Builder_Single`, `EventCollectorRuntime_Builder_Single`. Every AWS plugin builder
uses `makeFromCodeAsset` instead, which is why most components are unaffected — the leaks come from
core builders pulled in by an AWS component, which is what made defect 1 hard to trace statically.

`RuntimeEnvironment_Lambda.make` cannot simply be deleted: `Runtime.Environment` requires an
`environmentMaker`, and the in-memory platform implements it for real via `LocalRuntimeEnvironment`.
The documented remedy is an `_Ops.res` split plus `buildCodeArchive`, as already done for the presign
service and the geocoder.

## Method

Static tracing stalled on defect 1 and mis-identified the component twice. What worked was one
instrumented run: a `console.error` with a stack trace in the emitted `RuntimeEnvironment_Lambda.res.mjs`,
then a from-scratch `up`, which named the call site and its two callers outright. Prefer that.

## Guard worth adding

Consider making `RuntimeEnvironment_Lambda.make` log loudly (or fail) when reached from a deploy path,
so a serializing builder announces itself rather than going quiet. Also worth a check that the Lambda
count in a from-scratch stack matches the number of components expecting one — a cheap invariant that
would have caught both defects.
