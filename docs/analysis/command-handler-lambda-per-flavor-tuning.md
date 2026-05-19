# Per-flavor tuning of command-handler Lambdas

How to let app developers tune the four command-handler Lambdas independently:

- `AllAggregates` (sync aggregates, platform-wide)
- `AllAggregatesAsync` (async aggregates, platform-wide)
- `<Plugin>StateChanges` (sync DCB slices, per plugin)
- `<Plugin>StateChangesAsync` (async DCB slices, per plugin)

Companion to
[command-handler-lambda-naming-harmonization.md](done/command-handler-lambda-naming-harmonization.md)
which standardised the names. This one is about what knobs each Lambda exposes
and how to reach them.

## Current state

The runtime builders accept `~memorySize=1024` and `~timeout=30` as labeled
defaults on the `forCommandTopic` / `forCommandGenerator` / `forDcbCommandTopic`
runtime hooks, and the `Single` / `Single_Async` Pulumi builders take the
**max** across all registered components when sizing the bundled Lambda
([AggregateRuntime_Builder_Single.res:184-193](../../reventless/reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_Single.res#L184-L193)):

```rescript
let (parent, memorySize, timeout) = specs->Array.reduce((None, 0, 0), (
  (_, accMemorySize, accTimeout),
  {aggregateResource, memorySize, timeout},
) => {
  (
    aggregateResource.parent,
    Math.Int.max(accMemorySize, memorySize),
    Math.Int.max(accTimeout, timeout),
  )
})
```

But the call sites in
[Aggregate_Builder.res:89-92](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Builder.res#L89-L92)
never pass those args:

```rescript
commandTopic->AggregateRuntimeBuilder.forCommandTopic(
  ~handler,
  ~connect=SpecificCommandTopic.connect(commandTopic, ~resources, ...),
)
// no ~memorySize, no ~timeout → defaults apply (1024 / 30)
```

So every command-handler Lambda — sync or async, aggregate or DCB — currently
ships at **1024 MB memory and 30 s timeout**. SQS batch size, reserved
concurrency, ephemeral storage, log retention, and Lambda env vars are
similarly fixed at the framework defaults.

## Why sync and async want different settings

| Knob | Typical sync | Typical async | Reason |
|---|---|---|---|
| Lambda timeout | ≤ 30 s | up to 15 min | AppSync caps a synchronous Lambda invoke at 30 s. Async drains an SQS queue and can chew on long handlers. |
| Lambda memory | 512–1024 MB | 1024–2048 MB | Async batch-processes multiple records per invocation; sync handles one command at a time. |
| SQS batch size | 1–10 (queue is fallback) | 10–100 | Async throughput. |
| Reserved concurrency | floor (guarantee headroom for users) | cap (prevent runaway cost) | Inverse pressures — sync is user-facing, async is backpressure-tolerant. |
| Provisioned concurrency | sometimes (cold-start latency matters) | rarely | Sync = user-visible TTFB; async = queue. |
| Log retention | 1–7 days | 14–30 days | Async debugging often needs a longer trail. |
| Ephemeral storage (`/tmp`) | 512 MB default | sometimes more | Async batch handlers occasionally need scratch space. |

The case for per-flavor knobs is real and recurring.

## Proposal

Three layers, smallest-to-largest scope.

### Layer 1 — Platform-level config record (recommended)

Make `Platform.Make()` accept an optional `~commandHandlerConfig` record.
Every field in `commandHandlerConfig` is a ReScript optional field (`?`) —
callers omit the keys they don't care about; the framework defaults fill
the gaps. The four sub-fields (sync/async × aggregates/stateChanges) are
*also* optional fields, so callers can configure just one bucket and leave
the rest at defaults. All four buckets share the **same**
`commandHandlerConfig` shape — a Lambda is a Lambda, every knob is
meaningful for every flavor:

```rescript
module Platform = ReventlessAws.Platform.Make(
  ~commandHandlerConfig={
    aggregates: {
      sync:  {memorySize: 1024, timeout:  30, reservedConcurrency: 20},
      async: {memorySize: 2048, timeout: 300, sqsBatchSize: 50},
    },
    stateChanges: {
      sync:  {memorySize: 1024, timeout:  30, reservedConcurrency: 20},
      async: {memorySize: 2048, timeout: 300, sqsBatchSize: 50},
    },
  },
)
```

A minimal override that just bumps async aggregate memory and leaves the
other three Lambdas on defaults:

```rescript
module Platform = ReventlessAws.Platform.Make(
  ~commandHandlerConfig={aggregates: {async: {memorySize: 2048}}},
)
```

The name `commandHandlerConfig` is transport-neutral: the in-memory
platform ignores Lambda-specific knobs (memorySize, timeout, …) but still
honours `envVars`. Future transports (e.g. a Kubernetes platform) would
read the same record and map fields to their own runtime primitives.

The four sub-records map 1:1 to the four Lambdas (`AllAggregates`,
`AllAggregatesAsync`, `<Plugin>StateChanges`, `<Plugin>StateChangesAsync`).
Some fields are more relevant to async — `sqsBatchSize` controls the Route 2
SQS event source, which sync rarely uses heavily — but the framework
shouldn't bake that asymmetry into the type. If a user wants to tune Route 2
batching on sync (e.g. a plugin that publishes commands to the sync queue
from extensions), the knob is available.

**Plumbing.** Each runtime builder (`AggregateRuntime_Builder_Single`,
`_Single_Async`, `PluginRuntime_Builder`) reads from a module-level `ref`
that `Platform.Make()` sets:

```rescript
let aggregatesSyncConfig: ref<option<commandHandlerConfig>> = ref(None)
let setAggregatesSyncConfig = cfg => aggregatesSyncConfig := Some(cfg)
```

The existing unused `~memorySize` / `~timeout` args on `forCommandTopic` etc.
get folded into a `~config: option<commandHandlerConfig>` arg threaded through
the runtime hooks. The builder's `finish()` reads from the ref instead of
computing the max-of-zeros it does today.

**Pros.**

- Infra config lives in infra code (one obvious place).
- Same shape as every other Pulumi-Lambda-configuring API in the codebase.
- Single's "bundle everything" semantics work fine — one config per bundle.
- Sensible defaults stay in the builder; the record just overrides.

**Cons.**

- Same settings apply to all sync aggregates in the stack and to all sync
  slices in a plugin (matches the Single bundling pattern — features, not
  bugs).
- Can't (yet) target a single aggregate / slice with a custom Lambda config.

### Layer 2 — Per-component override via PPX (optional, later)

For legitimate outliers — one async slice needs 10 GB of memory because it
runs ML inference; one aggregate needs a 15-minute timeout because it
processes huge CSV imports — extend `@@reventless.async` with a payload:

```rescript
@@reventless.spec
@@reventless.async(memorySize=10240, timeout=900)
```

Or, for the case where a *sync* component needs an override too, introduce a
parallel attribute:

```rescript
@@reventless.spec
@@reventless.commandHandlerConfig(memorySize=2048, timeout=60)
```

The generator parses the attribute payload, stores it in `Pairing.resolved`,
and renders:

```rescript
module BigSlice = Platform.StateChangeSlice.MakeAsync(
  BigSlice,
  BigSlice_Behavior,
  ~commandHandlerConfig={memorySize: 10240, timeout: 900},
)
```

The Pulumi builder bundles into the per-plugin Lambda as before but takes
the max of platform-level config and per-component overrides — the same
`max()` reduce already in `finish()`, now with real data flowing in.

**Pros.**

- Per-component knobs for legitimate outliers.
- Composes with Layer 1 (platform-level floor; per-component ceiling).

**Cons.**

- Infrastructure decisions leak into spec files. A spec file is a
  domain-modeling artifact; threading Pulumi knobs through it dilutes that.
- PPX payload parsing + generator changes + Codegen branch — meaningful
  surface area for a use case that may never materialise.
- Easy to misuse ("just give this one slice more memory") as a substitute
  for fixing the actual hot path.

**Recommendation.** Skip Layer 2 until someone hits the wall. The
combination of Layer 1 (per-flavor) and Layer 3 (per-component via a
different deployment strategy) covers the legitimate cases.

### Layer 3 — Use `PerAggregate` / `Micro` strategies (already exist)

If you genuinely need per-component isolation — independent Lambda,
independent SQS, independent IAM role — the framework already has
`Aggregate_Builder_PerAggregate` and `Aggregate_Builder_Micro` strategies
that emit one Lambda per aggregate
([AggregateRuntime_Builder_PerAggregate.res](../../reventless/reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_PerAggregate.res),
[AggregateRuntime_Builder_Micro.res](../../reventless/reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_Micro.res)).
Applying Layer 1's config plumbing to those gives each per-aggregate Lambda
its own knobs.

The DCB side has no equivalent today — DCB is always one Lambda per plugin
per flavor. A `PluginRuntime_Builder_PerSlice` (or similar) would mirror the
Aggregate pattern. That's a separate proposal; bundling-strategy choice
deserves its own design discussion (cost / cold-start / deploy-churn
trade-offs).

**Pros.**

- True isolation: a runaway slice can't starve its plugin-mates.
- Independent CloudWatch log groups, IAM roles, alarms.
- Familiar Lambda-per-microservice mental model.

**Cons.**

- More Lambdas = more cold starts = higher tail latency.
- More IAM + more deploy churn for the same code change.
- Doesn't compose with the cost-optimisation goal that drove "Single" in
  the first place.

## Comparison

| | Layer 1 | Layer 2 | Layer 3 |
|---|---|---|---|
| Granularity | Per-flavor (4 buckets) | Per-component | Per-component |
| Where config lives | Pulumi code (`Platform.Make`) | Spec `.res` files (PPX) | Pulumi code (different builder) |
| Lambda count change | None | None | One per component (more) |
| Code surface | ~150 LOC, contained | PPX + generator + builders | New runtime builder |
| Operational impact | Zero (rolling Lambda config update) | Zero | Significant (Lambda topology changes) |
| Hits the wall when | Per-component outliers | Layer 1 isn't enough granularity | Real isolation needed |

## Recommendation

**Layer 1 is the right scope.** It matches the dominant Single deployment
pattern, plugs into existing builder structure cleanly, and gives the four
sensible knobs developers actually want to tune. The plumbing is contained
and reversible.

**Layer 2** is tempting but adds an axis of complexity (PPX payload parsing,
generator changes, per-component config merging) for a use case that
probably doesn't materialise. Skip until pressure exists.

**Layer 3** is orthogonal to flavor tuning — it's about Lambda bundling
strategy, not config. Treat as a separate design conversation if/when
per-component isolation becomes a goal.

## Implementation sketch (Layer 1 only)

### New type in `reventless-core`

```rescript
// reventless/reventless-core/src/adapter/Runtime/Runtime.res
type commandHandlerConfig = {
  memorySize?: int,                  // MB, 128–10240, framework default 1024
  timeout?: int,                     // seconds, 1–900, framework default 30
  reservedConcurrency?: int,         // None → unreserved (account-wide pool)
  sqsBatchSize?: int,                // Route 2 SQS event source, framework default 10
  ephemeralStorageMb?: int,          // /tmp size, 512–10240, AWS default 512
  logRetentionDays?: int,            // CloudWatch log-group retention, framework default 7
  envVars?: Js.Dict.t<string>,       // additional env vars (merged with built-ins)
}

type commandHandlerConfigFlavors = {
  sync?: commandHandlerConfig,
  async?: commandHandlerConfig,
}

type commandHandlerConfigs = {
  aggregates?: commandHandlerConfigFlavors,
  stateChanges?: commandHandlerConfigFlavors,
}
```

### Exposed defaults

So users can discover the framework's defaults at the type level and
compose against them (e.g. "use the default plus 50% memory"), expose
them as named constants in the same module:

```rescript
// reventless/reventless-core/src/adapter/Runtime/Runtime.res
module CommandHandlerDefaults = {
  let memorySize = 1024
  let timeout = 30
  let sqsBatchSize = 10
  let ephemeralStorageMb = 512
  let logRetentionDays = 7
}
```

Usage:

```rescript
open Reventless.Runtime
~commandHandlerConfig={
  aggregates: {
    async: {
      memorySize: CommandHandlerDefaults.memorySize * 2,  // 2048
      timeout: 300,
    },
  },
}
```

These constants are the **single source of truth** for "what does the
framework apply when the user says nothing." `makeFromCodeAsset` and the
SQS/CloudWatch resource builders all reference them; users can read them
too. There is no separate "default record" value — that would be a
parallel structure that could drift. Users who want a partly-tuned starting
point write their own preset literal and compose with spread:

```rescript
let highThroughputAsync: commandHandlerConfig = {
  memorySize: CommandHandlerDefaults.memorySize * 2,
  timeout: 300,
  sqsBatchSize: 50,
}

~commandHandlerConfig={
  aggregates: {async: {...highThroughputAsync, reservedConcurrency: 50}},
}
```

### Platform.Make changes

`reventless-aws/src/Platform.res` accepts an optional `~commandHandlerConfig`
labeled arg on the `Make` functor and dispatches to per-builder
`setConfig` calls:

```rescript
module Make = (~commandHandlerConfig: commandHandlerConfigs={}, ...) => {
  commandHandlerConfig.aggregates
  ->Option.forEach(({?sync, ?async}) => {
    sync->Option.forEach(AggregateRuntime_Builder_Single.setConfig)
    async->Option.forEach(AggregateRuntime_Builder_Single_Async.setConfig)
  })
  commandHandlerConfig.stateChanges
  ->Option.forEach(({?sync, ?async}) =>
    PluginRuntime_Builder.setStateChangesConfig(~sync?, ~async?)
  )
  // ... existing wiring
}
```

`~commandHandlerConfig: commandHandlerConfigs={}` lets callers omit the
arg entirely; the empty-record default means every sub-field is `None`,
every Lambda picks defaults. Each `Option.forEach` runs only when the
caller actually supplied that branch.

### Runtime builder changes

Each builder gets a module-level `ref` and reads from it in `finish()`:

```rescript
// AggregateRuntime_Builder_Single.res
let configRef: ref<commandHandlerConfig> = ref({})  // empty record; every field None
let setConfig = c => configRef := c

let finish = () =>
  if !finished.contents {
    // ...
    let cfg = configRef.contents
    let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
      ~name="AllAggregates",
      ~memorySize=?cfg.memorySize,
      ~timeout=?cfg.timeout,
      ~reservedConcurrency=?cfg.reservedConcurrency,
      ~ephemeralStorageMb=?cfg.ephemeralStorageMb,
      ~envVars=?cfg.envVars,
      // ...
    )
    // sqsBatchSize and logRetentionDays applied on dependent resources
    // (SQS event-source mapping, CloudWatch LogGroup).
  }
```

Every `commandHandlerConfig` field threads through as an optional pass-through arg
(`=?`). The framework's actual defaults — 1024 MB memory, 30 s timeout,
batch size 10 — live in `RuntimeEnvironment_Lambda.makeFromCodeAsset` (and
its callees for the dependent resources), not in every builder's
`finish()`. The empty-record initialiser at the top means "no overrides
set"; every consumer that asks for a value-with-default goes through one
canonical defaulting site.

Why centralise the defaults rather than `->Option.getOr(1024)` at each
call site: AWS Lambda's own defaults (128 MB / 3 s) are unusable for
command handlers, so the framework *must* supply sensible floors. Doing it
once in `makeFromCodeAsset` keeps `commandHandlerConfig` as a pure
"user-override" type and avoids drift between builders. The
`CommandHandlerDefaults` constants exposed above are the same values
`makeFromCodeAsset` substitutes in — readable and substitutable, but
written in exactly one place.

The existing reduce-max-across-aggregates logic is replaced by reading
from the config ref. The unused `~memorySize` / `~timeout` args on the
runtime hooks can stay (back-compat) or be dropped (cleaner) — they were
never wired through anyway.

### Lambda config application

Some knobs (memorySize, timeout) flow through
`RuntimeEnvironment_Lambda.makeFromCodeAsset` which already accepts them.
Others need post-construction Pulumi resources:

- `reservedConcurrency` → `PulumiAws.Lambda.FunctionEventInvokeConfig`
  or the `reservedConcurrentExecutions` arg on the Lambda itself
- `sqsBatchSize` → the SQS event-source mapping's `~batchSize` arg (where
  the builder creates that mapping)
- `logRetentionDays` → a `PulumiAws.CloudWatch.LogGroup` resource referencing
  the Lambda's name with the desired `retentionInDays`
- `ephemeralStorageMb` → `PulumiAws.Lambda.Function.ephemeralStorage`
- `envVars` → merged into the existing `envVars` dict before
  `makeFromCodeAsset`

### Scope of changes

| File | Lines (rough) |
|---|---|
| `Runtime.res` — new types | +20 |
| `Platform.res` — accept and dispatch config | +25 |
| `AggregateRuntime_Builder_Single.res` — config ref + apply | +40 |
| `AggregateRuntime_Builder_Single_Async.res` — same | +40 |
| `PluginRuntime_Builder.res` — sync/async config refs + apply | +50 |
| `RuntimeEnvironment_Lambda.res` — pass-through for new knobs | +30 |
| Tests | +60 |
| Docs | +40 |
| **Total** | ~300 LOC |

Non-breaking: every new arg is optional and defaults to current behavior.

### Out of scope for Layer 1

- `PerAggregate` and `Micro` Aggregate variants — the same pattern applies
  but the registry is per-aggregate, so the config record needs an extra
  dict for per-aggregate overrides. Defer.
- Per-component PPX attribute (Layer 2) — defer.
- DCB per-slice Lambdas (Layer 3) — defer.

## Decided

1. **Naming of the config record.** **`commandHandlerConfig`** — transport-neutral.
   `lambdaConfig` would imply AWS Lambda specifically, but the in-memory
   platform also reads (parts of) this record, and any future non-Lambda
   transport (e.g. Kubernetes) would too. The slightly longer name is
   worth the transport-neutrality.
4. **Defaults visibility.** Expose the framework's default values as named
   constants in a `CommandHandlerDefaults` submodule (see "Exposed defaults"
   in the implementation sketch). Users can read them, compose them
   (`CommandHandlerDefaults.memorySize * 2`), and build named presets on
   top — without the framework needing a parallel "default record" value
   that could drift.

## Still open

2. **Where do downstream consumers (extension authors) configure their own
   Lambdas?** The Plugin EventCollector, Heartbeat, Task, ExtensionPoint,
   and SideEffectHandler Lambdas all face the same gap. A consistent
   `commandHandlerConfigs`-style record covering all Lambda kinds would be
   a broader change; punt to a follow-up.
3. **Validation.** Pulumi will reject invalid Lambda configs at deploy
   time, but the framework could surface the constraints (memory range,
   timeout cap) at compile time via a smart constructor. Worth it?
   Probably not — defer to Pulumi's own validation.
