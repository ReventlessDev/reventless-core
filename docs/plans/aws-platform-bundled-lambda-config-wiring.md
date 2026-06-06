# Plan: AWS Platform — drop empty Config stubs, thread spec metadata per call

## Problem

`reventless-aws/src/Platform.res` instantiates the AWS-side runtime builders for **Task**, **ExtensionPoint** (four arity variants), and **Counter** by passing them a static `Config` module whose dicts/strings are all hardcoded empty:

```rescript
// Task.Make — line 415-422
Task_Builder_PerBucket.Make(Spec, {
  let callbackModulePaths = Dict.make()                  // ← empty
  let publishToAggregatesQueueUrls = Dict.make()         // ← empty
})

// ExtensionPoint.Make / .Make2 / .Make3 / .MakeMulti — lines 334, 356, 385, 395
ExtensionPoint_Builder.Make(Spec, Mappings, {
  let publishToAggregatesQueueUrls = Dict.make()         // ← empty
})

// Counter — line 425-429
Counter_Builder.Make(ApiConfig, {
  let specModulePath = ""                                // ← empty
  let mappingsModulePath = ""                            // ← empty
  let publishQueueUrl = Pulumi.Output.make("")           // ← empty
})
```

The dicts/strings are read by each runtime builder to populate the corresponding Lambda's `HANDLER_CONFIG` and env vars. With them empty:

1. **Task buckets** — `TaskRuntime_Builder_PerBucket.forBucketCallback` looks up `taskBucketInfos[name]`, finds nothing, and emits:
   ```
   TaskRuntime_Builder_PerBucket: no handler registered for bucket "<name>"
   ```
   …skipping Lambda creation entirely.
2. **Aggregate command publication** (Task / ExtensionPoint / Counter) — `HANDLER_CONFIG.publishToAggregates` is `{}`, no `PUBLISH_<Agg>_QUEUE_URL` env vars are set, and the bundled entry point's `PublishCommands(<agg>, ...)` action falls into the warn branch (e.g. `TaskBucketEntryPoint.mjs:41`).
3. **Counter** — `specModulePath` and `mappingsModulePath` empty means the cold-start `dynamicImport("")` fails; `publishQueueUrl` empty means counter callbacks have no SQS target.

The static-`Config` shape is the wrong abstraction: the values it tries to carry (spec module path, mapping module path, aggregate queue URLs) are **per-spec** facts already in scope inside the inner builder when its `make` is called — `Spec.moduleUrl` is injected by PPX, `allCommandTopics` is passed from `Plugin_Builder`. The Config is forced to be empty because there is nowhere upstream that has both the Spec and the aggregate outputs at functor application time.

## Fix

Stop threading per-spec metadata through static `Config` modules. Each runtime builder hook (`forBucketCallback` for Task, the corresponding hooks for ExtensionPoint and Counter) takes the spec/aggregate metadata as direct parameters from the inner builder, which already has them in scope. The `Config` modules go away entirely; `Platform.res` shrinks to one-liners per builder.

The plan breaks into three component-shaped passes (Task, ExtensionPoint, Counter), each following the same template, plus two cross-cutting steps (smoke test, schedule side-effects).

---

## Step 1 — Expose `moduleUrl` on `Task.Spec`

File: `reventless-infra/src/components/Task.res`

The `@@reventless.task` PPX already injects `let moduleUrl: string` into every Task spec module (see `reventless-ppx/src/ppx/ReventlessPpx.ml:602` — `dispatch_task_impl` adds it via `ModuleUrl.gen_module_url`). The interface just needs to publish it:

```rescript
module type Spec = {
  /** Logical task name (used as a Lambda function name prefix). */
  let name: string
  /** ESM specifier for this Spec module — populated by @@reventless.task PPX. */
  let moduleUrl: string
  let setup: setup
}
```

This matches the `moduleUrl` field already required by `StateChangeSlice.Spec`, `StateViewSlice.Spec`, etc. — Task is currently the odd one out.

## Step 2 — Add `~callbackModulePath` and `~publishToAggregatesQueueUrls` to `TaskRuntime_Builder.T.forBucketCallback`

File: `reventless-core/src/adapter/Runtime/TaskRuntime_Builder.res`

`Runtime.forComponentNamed` is shared with several other runtime builders, so don't add a parameter there. Instead, inline a slightly wider signature on this module's interface:

```rescript
module type T = {
  type context
  type callbackEvent
  type runtimeParts

  let forBucketCallback: (
    ~handler: Pulumi.Output.t<Runtime.eventHandler<callbackEvent, context, unit>>,
    ~connect: Runtime.connect<runtimeParts>,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~name: string,
    ~callbackModulePath: string,
    ~publishToAggregatesQueueUrls: dict<Pulumi.Output.t<string>>,
    Task.component,
  ) => unit
  let finish: unit => unit
}
```

## Step 3 — Pass `Spec.moduleUrl` and `allCommandTopics` from `Task_Builder`

File: `reventless-core/src/components/Task/Task_Builder.res:111`

`allCommandTopics` is already in scope at `Task_Builder.res:35`; turn it into the `aggName → queueUrl` dict the runtime builder expects:

```rescript
let publishToAggregatesQueueUrls =
  allCommandTopics->Dict.mapValues(ct => ct.queueUrl)
// ...
self->TaskRuntimeBuilder.forBucketCallback(
  ~handler=sideEffectHandler->createHandler(callback),
  ~connect=TaskBucket.connect(...),
  ~memorySize=4096,
  ~timeout=600,
  ~name=bucketName,
  ~callbackModulePath=Spec.moduleUrl,
  ~publishToAggregatesQueueUrls,
)
```

(The exact field-access for `queueUrl` follows whatever `Aggregate.allCommandTopics` already exposes — adapt to the existing shape.)

## Step 4 — Use the params directly in the AWS runtime builder

File: `reventless-aws/src/adapter/Runtime/TaskRuntime_Builder_PerBucket.res`

Drop the `taskBucketInfos` dict and `registerTaskBucket` registration step entirely; read both new parameters straight from the call:

```rescript
let forBucketCallback = (
  ~handler as _,
  ~connect,
  ~memorySize=4096,
  ~timeout=600,
  ~name,
  ~callbackModulePath,
  ~publishToAggregatesQueueUrls,
  task: ReventlessCore.Task.component,
) => {
  let resource = task->ReventlessCore.Component.toPulumiResource
  let fullName = resource.name->Option.getOr("UnnamedTask") ++ name
  // build envVars + HANDLER_CONFIG straight from callbackModulePath +
  // publishToAggregatesQueueUrls. No Dict.get / no warn-fallback path.
}
```

## Step 5 — Simplify `Task_Builder_PerBucket.Make`

File: `reventless-aws/src/components/Task_Builder_PerBucket.res`

`Config` is now empty. Delete `module type Config`, drop the second functor argument from `Make`, and remove the `Config.callbackModulePaths->Dict.forEachWithKey(...)` registration loop.

## Step 6 — Update `Platform.Task.Make`

File: `reventless-aws/src/Platform.res:415-422`

Drop the empty Config block:

```rescript
module Task = {
  module Make = (Spec: ReventlessInfra.Task.Spec): (
    ReventlessInfra.Task.T with module Spec = Spec
  ) => Task_Builder_PerBucket.Make(Spec)
}
```

## Step 7 — Local Task runtime builder

File: `reventless-core/src/adapter/Runtime/TaskRuntime_Builder_PerBucket.res`

This local (in-process) variant implements the same `TaskRuntime_Builder.T` interface; update its `forBucketCallback` to accept and ignore `~callbackModulePath` and `~publishToAggregatesQueueUrls` (in-process tasks don't need an ESM bundle path or SQS URLs).

---

## Step 8 — Apply the same pattern to all four `ExtensionPoint.Make` variants

Files: `reventless-aws/src/components/ExtensionPoint_Builder.res`, `reventless-aws/src/Platform.res:321-398`, plus the corresponding `ExtensionPointRuntime_Builder` (whichever runtime builder the AWS variant uses).

`ExtensionPoint_Builder.module type Config` currently carries only `publishToAggregatesQueueUrls: dict<Pulumi.Output.t<string>>` (line 5-7) and is consumed exactly once at line 27. Same root cause as Task:

```rescript
ExtensionPoint_Builder.Make(Spec, Mappings, {
  let publishToAggregatesQueueUrls = Dict.make()         // ← empty in all four variants
})
```

Affected sites in `Platform.res`:
- `ExtensionPoint.Make` (single mapping) — line 334
- `ExtensionPoint.Make2` (two mappings) — line 356
- `ExtensionPoint.Make3` (three mappings) — line 385
- `ExtensionPoint.MakeMulti` (variadic) — line 395

Apply the same refactor as Task:
1. Add `~publishToAggregatesQueueUrls` (and any other per-spec config the ExtensionPoint runtime builder reads) directly to the runtime hook used by `ExtensionPoint_Builder` — analogous to Task's `forBucketCallback`.
2. Have the inner builder pass `allCommandTopics`-derived URLs through that hook from inside its `make`.
3. Delete `ExtensionPoint_Builder.module type Config`, drop the third functor argument, and shrink all four `ExtensionPoint.Make*` bodies in `Platform.res` to a single line each:
   ```rescript
   module Make = ExtensionPoint_Builder.Make
   module Make2 = ExtensionPoint_Builder.Make2
   module Make3 = ExtensionPoint_Builder.Make3
   module MakeMulti = ExtensionPoint_Builder.MakeMulti
   ```
   (or whatever the post-refactor module structure ends up looking like).

After this step, the catalog plugin's `Orders_Extension` and any other extension-via-extension-point in the hybrid example actually receives `PUBLISH_<Agg>_QUEUE_URL` env vars in its bundled Lambda — currently it doesn't, despite no warning ever firing.

## Step 9 — Apply the same pattern to `Counter`

File: `reventless-aws/src/Platform.res:425-429`, plus `Counter_Builder` and the AWS Counter runtime adapter.

`Counter` has a wider Config with three empty fields: `specModulePath = ""`, `mappingsModulePath = ""`, `publishQueueUrl = Pulumi.Output.make("")`. Same fix shape:

1. Surface `Spec.moduleUrl` (and the mapping module URL — likely already injected by PPX or available as `Mappings.moduleUrl`) on whatever Spec/Mappings interface `Counter_Builder` consumes.
2. Replace the Config dict with direct parameters on the Counter runtime builder's per-call hook.
3. `publishQueueUrl` is the per-spec aggregate the counter publishes to — derive it the same way as Task's `publishToAggregatesQueueUrls`, but pick the single relevant aggregate from `allCommandTopics`.
4. Drop `Config` from `Counter_Builder.Make`, shrink `Platform.Counter` to:
   ```rescript
   module Counter = Counter_Builder.Make(ApiConfig)
   ```

Note: `Counter` is currently unused by the online-shop examples and any business-repo plugin (grep returns zero hits outside framework internals). The fix is still worth doing in the same pass because the broken Config shape is identical to Task/ExtensionPoint and someone enabling Counter later will rediscover the gap.

## Step 10 — Cleanup: align `ReadModel_Builder_PerReadModel` with the new pattern

File: `reventless-aws/src/components/ReadModel_Builder_PerReadModel.res`.

This builder declares the same `module type Config = { specModulePath: string; mappingsModulePath: string }` design (lines 6-9) and is **never called** from `Platform.res` — `Platform.ReadModel.Make` uses `ReadModel_Builder_Single` and the admin-side `PluginReadModel` / `PlatformEventGraphReadModel` use `ReadModel_Builder_NoResolver`. Today it's dead code, but the comment at `Platform.res:285-288` ("To override per-plugin or per-aggregate, swap the builder at the call site, e.g., `_PerReadModel`") explicitly invites users to wake it up — the moment anyone does, they'll hit the same empty-Config wall as Task/ExtensionPoint/Counter.

While doing the refactor in Steps 5/8/9, give `_PerReadModel` the same treatment: drop `module type Config`, derive `specModulePath` from `Spec.moduleUrl` inside the builder via `Util_Bundle.getModuleSpecifier` (same way the Aggregate variants already do — see `Aggregate_Builder_Single.res:48`, `Aggregate_Builder_PerAggregate.res:46`, `Aggregate_Builder_Single_Async.res:48`), and either treat `mappingsModulePath` as optional (matching `Aggregate_Builder_Micro.res:9`'s `option<string>`) or surface it from a Mappings interface field.

Audit boundary: this completes the sweep of `module type Config` declarations under `reventless-aws/src/components/` — there are exactly four (`Counter_Builder`, `ExtensionPoint_Builder`, `Task_Builder_PerBucket`, `ReadModel_Builder_PerReadModel`), all covered above. `Aggregate_Builder_Micro` has a `MappingsConfig` with an `option<string>` field, which is a legitimate optional rather than an empty stub — left as-is.

## Step 11 — Implement schedule side-effects in the Task Lambda

File: `reventless-aws/src/adapter/Runtime/TaskBucketEntryPoint.mjs:45-50`.

`CreateSchedule` and `DeleteSchedule` are explicitly stubbed with `console.warn("...not supported in bundled mode")`. Tasks that schedule themselves (re-run after delay, defer until a deadline, etc.) silently do nothing.

The Task spec's `setup` already returns `config.sideEffects` and `Task_Builder.construct` (`Task_Builder.res:43-55`) constructs a `SpecificSideEffectHandler` when present, which exposes a `SideEffectHandler.operations` value with `createSchedule` / `deleteSchedule` functions. That handler is then **discarded** because the AWS runtime builder rebuilds the callback from `Spec.moduleUrl` on cold start without the operations.

To wire it on AWS:

1. The `SpecificSideEffectHandler.make` invocation needs to surface as a deploy-time output: scheduler ARN / role ARN / EventBridge group, etc., so the Task Lambda can call CreateSchedule/DeleteSchedule against the real AWS scheduler. These outputs already exist for other components — reuse them via `~scheduler` (already passed to `Task_Builder.construct`).
2. Encode the scheduler endpoint and role ARN into `HANDLER_CONFIG` (or as additional `SCHEDULER_*` env vars).
3. Replace the two `console.warn` lines in `TaskBucketEntryPoint.mjs` with calls to a small `Scheduler_Aws_Runtime` helper that wraps `@aws-sdk/client-scheduler`'s `CreateScheduleCommand` / `DeleteScheduleCommand`, mirroring the `sqsPublishJsons` pattern already in the file.
4. Cover with a smoke test: deploy a Task whose `setup` returns a `CreateSchedule` action; assert the schedule lands in EventBridge and `DeleteSchedule` removes it.

This step depends on Steps 1–7 landing first (the entry point needs the `Spec.moduleUrl` rewire before adding scheduler plumbing on top).

## Step 12 — Smoke-test against the hybrid example

After all of the above compiles, redeploy the `online-shop-hybrid/catalog-aws` example stack. Verify, for each affected component class:

**Task (`ImportProducts` / `product-imports` bucket):**
1. No `TaskRuntime_Builder_PerBucket: no handler registered for bucket "product-imports"` warning during `pulumi up`.
2. A new Lambda function appears with name suffix `product-imports`.
3. The Lambda's `HANDLER_CONFIG` env var contains the spec's ESM specifier (the `Spec.moduleUrl` value).
4. The Lambda has `PUBLISH_<Agg>_QUEUE_URL` env vars for every aggregate the catalog plugin exposes.
5. A scheduled side-effect (if added to the spec for the test) creates and deletes an EventBridge schedule end-to-end.

**ExtensionPoint (`Products_ExtensionPoint`):**
6. The extension-point Lambda has `PUBLISH_<Agg>_QUEUE_URL` env vars for every aggregate referenced by its mappings (today it has none).
7. A subscriber-side `PublishCommands(<agg>, ...)` action successfully reaches the target aggregate.

**Counter (if any counter is wired into the example):**
8. The counter Lambda imports the spec and mapping modules from the bundled paths (today the import string is empty and the cold start fails silently or noisily).
9. The counter publishes to its single target aggregate via the resolved `publishQueueUrl`.
