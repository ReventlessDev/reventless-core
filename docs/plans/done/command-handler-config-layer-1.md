# `commandHandlerConfig` — Layer 1 (platform-level per-flavor tuning)

Implements Layer 1 from
[docs/analysis/command-handler-lambda-per-flavor-tuning.md](../analysis/command-handler-lambda-per-flavor-tuning.md):
a `~commandHandlerConfig` record on `Platform.Make()` that lets app developers
tune the four command-handler Lambdas independently:

- `AllAggregates` (sync aggregates, platform-wide)
- `AllAggregatesAsync` (async aggregates, platform-wide)
- `<Plugin>StateChanges` (sync DCB slices, per plugin)
- `<Plugin>StateChangesAsync` (async DCB slices, per plugin)

Layer 2 (per-component PPX override) and Layer 3 (per-component
deployment strategy) are out of scope; see analysis.

## Acceptance

After this lands, a user can write:

```rescript
module Platform = ReventlessAws.Platform.Make(
  ~commandHandlerConfig={
    aggregates: {
      async: {memorySize: 2048, timeout: 300, sqsBatchSize: 50},
    },
    stateChanges: {
      async: {memorySize: 2048, reservedConcurrency: 50},
    },
  },
)
```

…and observe on `pulumi up`:

- `AllAggregatesAsync` Lambda gets memory 2048 MB, timeout 300 s; its SQS
  event-source mapping gets batchSize 50.
- `<Plugin>StateChangesAsync` Lambda gets memory 2048 MB; its Lambda's
  `reserved_concurrent_executions` is set to 50.
- `AllAggregates` and `<Plugin>StateChanges` Lambdas keep framework
  defaults (1024 MB / 30 s / batch 10).
- Empty / omitted record yields today's behavior on every Lambda.

A user can also reference framework defaults at call sites:

```rescript
~commandHandlerConfig={
  aggregates: {
    async: {memorySize: Reventless.Runtime.CommandHandlerDefaults.memorySize * 2},
  },
}
```

## Out of scope

- Per-component overrides via PPX (Layer 2 in the analysis).
- DCB per-slice Lambda topology (Layer 3).
- Extending the same record to Plugin EventCollector / Heartbeat / Task /
  ExtensionPoint / SideEffectHandler Lambdas (analysis "Still open" #2).
- Compile-time validation of memory/timeout ranges (analysis "Still open" #3).
- Aggregate `PerAggregate` / `Micro` strategies — they have their own
  registration paths; same pattern applies but warrants a follow-up plan
  if/when needed.

## Steps

### Step 1 — Types and defaults in `reventless-core`

[reventless/reventless-core/src/adapter/Runtime/Runtime.res](../../reventless/reventless-core/src/adapter/Runtime/Runtime.res),
add at the bottom (or in a logical position next to the existing
`forComponent` etc. type aliases):

```rescript
type commandHandlerConfig = {
  memorySize?: int,                  // MB, 128–10240
  timeout?: int,                     // seconds, 1–900
  reservedConcurrency?: int,         // None → unreserved
  sqsBatchSize?: int,                // Route 2 SQS event source
  ephemeralStorageMb?: int,          // /tmp size, 512–10240
  logRetentionDays?: int,            // CloudWatch log-group retention
  envVars?: dict<string>,            // merged with framework-set env vars
}

type commandHandlerConfigFlavors = {
  sync?: commandHandlerConfig,
  async?: commandHandlerConfig,
}

type commandHandlerConfigs = {
  aggregates?: commandHandlerConfigFlavors,
  stateChanges?: commandHandlerConfigFlavors,
}

module CommandHandlerDefaults = {
  let memorySize = 1024
  let timeout = 30
  let sqsBatchSize = 10
  let ephemeralStorageMb = 512
  let logRetentionDays = 7
}
```

`dict<string>` over `Js.Dict.t<string>` matches the rest of the codebase.

### Step 2 — Extend `RuntimeEnvironment_Lambda.makeFromCodeAsset`

[reventless/reventless-aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res:67-82](../../reventless/reventless-aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res#L67-L82),
add the new optional args. Memory and timeout already exist (just expand
internal defaults to reference `CommandHandlerDefaults`).

```rescript
let makeFromCodeAsset: (
  ~name: string,
  ~code: Pulumi.Archive.t,
  ~sourceCodeHash: string,
  ~envVars: dict<Pulumi.Input.t<string>>=?,
  ~memorySize: int=?,
  ~timeout: int=?,
  ~reservedConcurrency: int=?,                  // NEW
  ~ephemeralStorageMb: int=?,                   // NEW
  ~logRetentionDays: int=?,                     // NEW
  ~opts: Pulumi.ComponentResource.options=?,
) => ReventlessCore.Runtime.environment<parts> = (
  ~name,
  ~code,
  ~sourceCodeHash,
  ~envVars=Dict.make(),
  ~memorySize=ReventlessCore.Runtime.CommandHandlerDefaults.memorySize,
  ~timeout=ReventlessCore.Runtime.CommandHandlerDefaults.timeout,
  ~reservedConcurrency=?,
  ~ephemeralStorageMb=?,
  ~logRetentionDays=?,
  ~opts=?,
) => {
  // ...
  let lambda = Lambda.Function.make(
    ~name,
    ~args={
      // ... existing fields ...
      memorySize: memorySize->Pulumi.Input.make,
      timeout: timeout->Pulumi.Input.make,
      reservedConcurrentExecutions: ?reservedConcurrency->Option.map(Pulumi.Input.make),
      ephemeralStorage: ?ephemeralStorageMb->Option.map(mb =>
        ({size: mb->Pulumi.Input.make}: Lambda.Function.ephemeralStorage)->Pulumi.Input.make
      ),
      // ...
    },
  )

  // If logRetentionDays is set, create a CloudWatch LogGroup with the
  // matching name and retention; otherwise Lambda auto-creates one with
  // no retention (logs accumulate indefinitely).
  logRetentionDays->Option.forEach(days => {
    let _ = PulumiAws.CloudWatch.LogGroup.make(
      ~name=`${name}LogGroup`,
      ~args={
        name: `/aws/lambda/${name}`->Pulumi.Input.make,
        retentionInDays: days->Pulumi.Input.make,
      },
      ~opts?,
    )
  })

  // ...
}
```

Verify that `Lambda.Function.functionArgs` in `rescript-pulumi-aws` already
exposes `reservedConcurrentExecutions` and `ephemeralStorage`. If not,
extend the binding first.

### Step 3 — SQS event-source batchSize pass-through

The SQS event-source mapping is created inside
`CommandTopicChannel_SQS_Runtime.handleQueueEvent` and similar — they call
`PulumiAws.Lambda.EventSourceMapping.make`. Add an optional `~batchSize=?`
threaded through.

Find every call site of `handleQueueEvent` (in `AggregateEntryPoint.mjs` and
the runtime builders that wire SQS event sources at deploy time — these are
in `CommandTopicChannel_SQS_Sync.res` and `_Async.res`'s `connect` / wiring
helpers) and add the optional arg. Default to
`CommandHandlerDefaults.sqsBatchSize` when not supplied.

### Step 4 — Module-level config refs in the three runtime builders

Three builders own the four Lambdas:

| Lambda | Builder |
|---|---|
| `AllAggregates` | [AggregateRuntime_Builder_Single.res](../../reventless/reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_Single.res) |
| `AllAggregatesAsync` | [AggregateRuntime_Builder_Single_Async.res](../../reventless/reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_Single_Async.res) |
| `<Plugin>StateChanges` | [PluginRuntime_Builder.res](../../reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res) (sync branch — `isAsync = false`) |
| `<Plugin>StateChangesAsync` | same builder, async branch (`isAsync = true`) |

In each, add a module-level ref and `setConfig` helper:

```rescript
// AggregateRuntime_Builder_Single.res — add near top
let configRef: ref<ReventlessCore.Runtime.commandHandlerConfig> = ref({})
let setConfig = c => configRef := c
```

```rescript
// AggregateRuntime_Builder_Single_Async.res — same
```

```rescript
// PluginRuntime_Builder.res — needs both flavors
let syncStateChangesConfigRef: ref<ReventlessCore.Runtime.commandHandlerConfig> = ref({})
let asyncStateChangesConfigRef: ref<ReventlessCore.Runtime.commandHandlerConfig> = ref({})
let setStateChangesConfig = (~sync=?, ~async=?, ()) => {
  sync->Option.forEach(c => syncStateChangesConfigRef := c)
  async->Option.forEach(c => asyncStateChangesConfigRef := c)
}
```

### Step 5 — Apply config in each builder's `finish()` / Lambda-creation site

[AggregateRuntime_Builder_Single.res:252-260](../../reventless/reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_Single.res#L252-L260)
— replace the current call:

```rescript
// Before
let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
  ~name="AllAggregates",
  ~code,
  ~sourceCodeHash,
  ~envVars,
  ~memorySize,
  ~timeout,
  ~opts,
)
```

```rescript
// After
let cfg = configRef.contents
let envVarsMerged = ... // merge cfg.envVars into envVars
let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
  ~name="AllAggregates",
  ~code,
  ~sourceCodeHash,
  ~envVars=envVarsMerged,
  ~memorySize=?cfg.memorySize,
  ~timeout=?cfg.timeout,
  ~reservedConcurrency=?cfg.reservedConcurrency,
  ~ephemeralStorageMb=?cfg.ephemeralStorageMb,
  ~logRetentionDays=?cfg.logRetentionDays,
  ~opts,
)
```

Drop the now-unused `let (parent, memorySize, timeout) = specs->Array.reduce(...)`
(or simplify to compute only `parent`). The existing reduce was taking the
max of zeros and never produced useful values.

Apply the same change in `AggregateRuntime_Builder_Single_Async.res` and in
`PluginRuntime_Builder.res` (selecting `syncStateChangesConfigRef` vs
`asyncStateChangesConfigRef` by the `isAsync` flag already in scope).

Wire `sqsBatchSize` into the SQS event-source mapping creation (this
likely happens via the `connect` callbacks invoked just after the runtime
is built — confirm by tracing `cmdTopicResource.connect` in each builder).

### Step 6 — `Platform.Make()` accepts `~commandHandlerConfig`

[reventless/reventless-aws/src/Platform.res](../../reventless/reventless-aws/src/Platform.res),
add the labeled arg and dispatch:

```rescript
module Make = (~commandHandlerConfig: ReventlessCore.Runtime.commandHandlerConfigs={}, ...) => {
  commandHandlerConfig.aggregates
  ->Option.forEach(({?sync, ?async}) => {
    sync->Option.forEach(AggregateRuntime_Builder_Single.setConfig)
    async->Option.forEach(AggregateRuntime_Builder_Single_Async.setConfig)
  })
  commandHandlerConfig.stateChanges
  ->Option.forEach(({?sync, ?async}) =>
    PluginRuntime_Builder.setStateChangesConfig(~sync?, ~async?, ())
  )
  // ... existing functor body
}
```

The empty-record default (`= {}`) lets callers omit the arg entirely. The
nested `Option.forEach` chains apply only when the caller supplied that
branch — every other Lambda picks defaults.

### Step 7 — In-memory platform (parity)

[reventless/reventless-in-memory/src/Platform.res](../../reventless/reventless-in-memory/src/Platform.res)
should accept the same `~commandHandlerConfig` arg for type-checking parity,
but most fields are no-ops in-memory. The two that *do* apply:

- `envVars` — merge into the platform's process env or per-component context.
- (everything else logged as ignored, or silently ignored.)

If parity is too noisy at this stage, defer and document the in-memory
asymmetry — the in-memory and AWS platform signatures already differ in
several places. Decision point: include or defer? Default to **defer**
unless it surfaces a type-check error in shared code.

### Step 8 — Build, verify, run tests

```bash
pnpm run build
pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"   # must be empty

pnpm --filter='./reventless/reventless-core' test
pnpm --filter='./reventless/reventless-in-memory' test
pnpm --filter='./reventless/reventless-aws' test
pnpm --filter='./examples/online-shop-aggregates/catalog' test
pnpm --filter='./examples/online-shop-aggregates/ordering' test
pnpm --filter='./examples/online-shop-dcb/catalog' test
pnpm --filter='./examples/online-shop-dcb/ordering' test
```

New tests to add (`reventless/reventless-aws/tests/Runtime/`):

- `commandHandlerConfig` defaults flow through when the arg is omitted —
  assert Lambda Pulumi resource has `memorySize=1024`, `timeout=30`,
  `reservedConcurrentExecutions` absent.
- Sync aggregate override sets only the `AllAggregates` Lambda — async
  Lambda stays on defaults.
- Async StateChanges override sets only `<Plugin>StateChangesAsync` —
  sync DCB Lambda stays on defaults.
- `sqsBatchSize` flows to the SQS event-source mapping (assert on the
  Pulumi resource args).
- `envVars` from the config record are merged with framework-set env
  vars (DISPATCH_MODE, HANDLER_CONFIG, …) and the framework's win on key
  collision.

### Step 9 — Update docs

- [docs/guides/lambda-deployment.md](../guides/lambda-deployment.md) — add a
  "Tuning the command-handler Lambdas" section pointing at
  `~commandHandlerConfig`.
- [packages/doc/docs-app/components/commandtopic.md](../../packages/doc/docs-app/components/commandtopic.md)
  — under the "Sync vs async" section, add a note that knobs are per-flavor
  configurable; link to the deployment guide.
- [.claude/rules/app-developer.md](../../.claude/rules/app-developer.md) —
  one-line entry for `~commandHandlerConfig` near where `@@reventless.async`
  is documented.
- New file:
  [packages/doc/docs-app/components/command-handler-config.md](../../packages/doc/docs-app/components/command-handler-config.md)
  (or inline section) showing the full type, the `CommandHandlerDefaults`
  constants, and worked examples.

### Step 10 — Move plan to `done/`

Use `git mv` (the plan file is committed by the time Step 9 lands):

```bash
git mv docs/plans/command-handler-config-layer-1.md docs/plans/done/
```

Then commit the move with the final implementation chunk.

## Commit shape

Single commit, conventional-commits prefix `feat`:

```
feat(platform): commandHandlerConfig for per-flavor Lambda tuning

Adds ~commandHandlerConfig to Platform.Make() — a record covering the
four command-handler Lambdas:

  aggregates: {sync, async}
  stateChanges: {sync, async}

Every field is an optional record field (memorySize, timeout,
reservedConcurrency, sqsBatchSize, ephemeralStorageMb, logRetentionDays,
envVars). Users supply only what they want to override; the framework
fills the rest from CommandHandlerDefaults (1024 MB / 30 s / batch 10).

The defaults are exposed as named constants so users can compose
against them:

  ~commandHandlerConfig={
    aggregates: {
      async: {memorySize: CommandHandlerDefaults.memorySize * 2},
    },
  }

Async Lambdas are only provisioned when at least one component opts in
via @@reventless.async, so the async sub-records simply have no effect
on sync-only setups.

Plan: docs/plans/done/command-handler-config-layer-1.md
Analysis: docs/analysis/command-handler-lambda-per-flavor-tuning.md
```

No breaking-change footer — every new arg is optional, defaults preserve
today's behavior. PerAggregate and Micro builders are untouched; their
own tuning is a follow-up.
