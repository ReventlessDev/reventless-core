# Lambda Deployment Architecture

This guide explains how Reventless deploys Lambda handlers on AWS, how this relates to the **local** and **AWS** platforms, and the conventions for writing platform-agnostic vs. AWS-specific plugin code.

For related guides, see:
- [Application Development Layers](/framework/application-development-layers) — the three-layer architecture
- [Platform and Plugin Guide](/app/platform-and-plugin-guide) — creating platforms and plugins
- [Deployment Guide](deployment-guide.md) — per-plugin AWS deployment with Pulumi

---

## 1. Background: Why Lambda Code Assets Are Used

### The Pulumi Serialization Problem

Reventless uses [Pulumi](https://www.pulumi.com/) for infrastructure-as-code. Originally, Lambda handlers were deployed using Pulumi's `CallbackFunction`, which serializes JavaScript closures at deploy time. This worked until the framework adopted [Effect-TS](https://effect.website/) for structured concurrency and error handling.

Effect-TS modules contain non-serializable objects (fiber runtimes, unbound console functions, mutable scheduler state). When a handler closure captures `Effect.runPromise`, Pulumi's V8 serializer fails:

```
error: Error serializing '(event, ctx) => Effect.Effect.runPro ...':
  captured variable 'Effect' which indirectly referenced
    FiberRuntime -> consoleTag -> function is not a bound function
```

This is not a bug that can be worked around at individual call sites. Business logic handlers throughout `reventless-aws` (EventLogStorage, CommandTopicChannel, QueryDb, etc.) all use Effect internally. The serialization walker traverses the entire closure graph and hits non-serializable objects deep in the dependency tree.

See `docs/analysis/done/pulumi-effect-serialization.md` for the full analysis.

### The Code-Asset Solution

Instead of serializing closures, all Lambda handlers:

1. **Generate** a JavaScript entry point file (source code string) that imports the handler's spec and behavior modules
2. **Bundle** it with esbuild into a self-contained `index.mjs`
3. **Upload** the bundle as a code asset to `aws.lambda.Function` (not `CallbackFunction`)
4. **Pass infrastructure references** (table names, queue URLs) via environment variables instead of captured closure values

No closure serialization occurs. Pulumi manages only the infrastructure resources; the handler code is a plain file.

---

## 2. Architecture Overview

### Two Platforms, One Interface

The framework provides two platform implementations behind the same `ReventlessInfra.Platform.T` module type:

| | Local | AWS |
|---|---|---|
| **Package** | `reventless-local` | `reventless-aws` |
| **`type api`** | `unit` | `Types.AppSync.api` |
| **`type role`** | `unit` | `Types.AppSync.role` |
| **Event storage** | In-memory / SQLite | DynamoDB |
| **Command dispatch** | In-process bus | SQS FIFO |
| **Event fan-out** | In-process bus | DynamoDB Streams |
| **Query storage** | In-memory / SQLite | DynamoDB + GSI |
| **Handler runtime** | Deferred promise | Lambda function |
| **API** | GraphQL Yoga (local) | AppSync |
| **Used for** | Tests, local dev | Production deployment |

Plugin code that uses only `Platform.T` works identically on both platforms. The platform determines the concrete adapters.

### Three Development Layers

```
Layer 1 — Domain Specification    (deps: reventless-spec)
Layer 2 — Plugin Assembly         (deps: reventless-spec + reventless-infra)
Layer 3 — Composition Root        (deps: reventless-infra + reventless-aws or reventless-local)
```

Layer 2 is where plugin functors live. They accept a `Platform: ReventlessInfra.Platform.T` parameter and use `Platform.Aggregate.Make`, `Platform.ReadModel.Make`, etc. This is platform-agnostic code.

Layer 3 instantiates a concrete platform (`ReventlessAws.Platform.Make()` or `ReventlessLocal.Platform.Make()`) and passes it to the plugin functor. This is the only layer that names a specific provider.

### Where AWS Builders Fit

Aggregates, ReadModels, and ExtensionPoints register Lambda handlers when their `Platform.*.Make` functor runs against the AWS Platform. These functors live behind `Platform.T` — plugin code never names `ReventlessAws.*` builders directly. The AWS-specific builder strategy is internal to `reventless-aws`'s Platform implementation.

```
┌─────────────────────────────────────────────────────┐
│  Plugin.res (auto-generated, Layer 2 — platform-agnostic)  │
│    Platform.Aggregate.Make(Category, ...)           │
│    Platform.StateViewSlice.Make(ProductsView)       │
└────────────────────┬────────────────────────────────┘
                     │ used by both:
    ┌────────────────┼────────────────────┐
    │                │                    │
    ▼                ▼                    ▼
  Tests          Local Dev          AWS deployment
  (in-memory)    (GraphQL Yoga)     (Lambda + DynamoDB + AppSync)
```

The `*-aws` package adds a thin Layer 3 wrapper that picks the AWS Platform; it does not redeclare any of the plugin's components.

---

## 3. AWS Plugin Variants: `Plugin.res` Files

### Platform-Agnostic (via `Platform.T`)

The standard plugin package (`catalog/`, `ordering/`) generates a Layer 2 `Plugin.res` that works with any platform:

```rescript
// Layer 2 — auto-generated; works with any platform
module Make = (Platform: ReventlessInfra.Platform.T) => {
  module CategoryAggregate = Platform.Aggregate.Make(
    Category, CategoryBehavior, ReventlessInfra.NoEventMappings.Make(Category),
  )
  module OrdersViewSlice = Platform.StateViewSlice.Make(OrdersView, OrdersView_Projection)
  // ... aggregates, readmodels, slices, extensionpoints, extensions ...

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(~name="Catalog", ~heartbeatInterval=60, /* ... */)
}
```

- Works with in-memory (tests, local dev) and AWS (production) — the platform decides whether `Platform.Aggregate.Make` registers an in-process bus subscriber or a Lambda handler.
- For plugins with aggregates or read models, the generator emits an optional `~uiBundleUrl=?` parameter that builds an AutoUI manifest when set (see `platform-and-plugin-guide.md` → AutoUI).

### AWS-Specific Wrapper

The `*-aws` package's `Plugin.res` is auto-generated by `generate-plugin --aws <Namespace> ../<plugin>/src/`. It is a thin delegating wrapper over the standard plugin's `Make` functor; it does not redeclare any components:

```rescript
// AUTO-GENERATED — Layer 3, catalog-aws/src/Plugin.res
@val external uiBundleUrl: option<string> = "process.env.CATALOG_UI_BUNDLE_URL"

module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  module Composition = CatalogPlugin.Plugin.Make(Platform)
  let make = () => Composition.make(~uiBundleUrl?)
}
```

Why a wrapper at all rather than `Plugin.Make(Platform)` directly in `Main.res`?
- The AWS deployer requires `PluginMaker.make: unit => component`. The standard plugin's `make: (~uiBundleUrl: string=?, unit) => component` does not match that module type, so the wrapper eta-expands to `() => Composition.make(...)`.
- The AWS variant reads its UI bundle URL from `<PLUGIN>_UI_BUNDLE_URL` (PascalCase → SCREAMING_SNAKE_CASE) so the same env-var name works for both deploy paths. Unset → no UI fragments.

If a plugin has neither aggregates nor read models, the generator emits `let make = () => Composition.make()` and skips the env-var binding entirely.

### Handler Configuration

Each AWS builder extracts module paths at deploy time so the generated Lambda entry point can `import` the right spec and behavior modules at runtime. These paths are resolved using `Util_Bundle.getModuleSpecifier`, which converts `import.meta.url` to an importable module specifier.

| Component | Config extracted from |
|---|---|
| Aggregate | `Spec.moduleUrl`, `Behavior.moduleUrl` |
| ReadModel | `Spec.moduleUrl`, `Mappings.moduleUrl` |
| ExtensionPoint | `Spec.moduleUrl`, `Mappings.moduleUrl` |
| StateViewSlice | `Spec.moduleUrl` |
| AutomationSlice | `Spec.moduleUrl` |
| OutboundTranslationSlice | `Spec.moduleUrl` |
| Task | callback module URLs, `publishToAggregatesQueueUrls` |
| Counter | target spec URL, mappings URL, publish queue URL |

### Which Components Create Lambda Handlers

All component creation flows through `Platform.T` — what differs is whether the AWS Platform's implementation registers a Lambda for each component type and when that Lambda is created.

| Component | Lambda created? | When |
|---|---|---|
| Aggregate | Yes | Eagerly on `Platform.Aggregate.Make` (per-aggregate command handler) |
| ReadModel | Yes | Eagerly on `Platform.ReadModel.Make` (event projection handler) |
| ExtensionPoint | Yes | Eagerly on `Platform.ExtensionPoint.Make` (per-EP command handler) |
| Task | Yes | Eagerly on `Platform.Task.Make` |
| Extension | No | Maps events between EPs; no own handler |
| StateChangeSlice | No own | Events flow through the shared DCB CommandTopic Lambda |
| StateViewSlice | Yes (deferred) | Lambda created by `finish()` via `onDcbSlicesCreated` hook |
| AutomationSlice | Yes (deferred) | Lambda created by `finish()` via `onDcbSlicesCreated` hook |
| OutboundTranslationSlice | Yes (deferred) | Lambda created by `finish()` via `onDcbSlicesCreated` hook |
| InboundTranslationSlice | Yes (deferred) | Lambda created by `finish()` via `onDcbSlicesCreated` hook |
| DcbEventLog | No | Infrastructure only (DynamoDB table) |
| Counter | No own | Created inside the Platform functor; uses ReadModel handlers |

---

## 4. The Lambda Handler Pipeline

When an AWS component builder is called, the following pipeline runs at deploy time:

```
1. Component builder calls RuntimeBuilder.registerXxx (or forEventCollector / forCommandTopic)
   │  → accumulates handler specs in a module-level dict (does NOT create Lambda yet)
   │
2. RuntimeBuilder.finish() is called (after all components registered)
   │
3. Util_EntryPoint.generateXxxEntryPoint() creates JS source code:
   │  import { makeHandler } from "AggregateHandlerFactory.mjs";
   │  import * as Spec from "<specModulePath>";
   │  import * as Behavior from "<behaviorModulePath>";
   │  const handler = makeHandler(Spec, Behavior, process.env.TABLE_NAME, ...);
   │  export { handler };
   │
4. Util_Bundle.bundleEntryPoint() runs esbuild:
   │  → writes JS to temp file, bundles to index.mjs, returns Zip archive
   │
5. RuntimeEnvironment_Lambda.makeFromCodeAsset() creates:
   │  → IAM role
   │  → aws.lambda.Function with code asset + env vars + Lambda Layer
   │
6. EventCollectorChannel.connect() wires DynamoDB Stream triggers
```

### The Lambda Layer

All Lambda handlers share a pre-built Lambda Layer (`reventless-layer-builder`) containing common dependencies:

| Package | Purpose |
|---|---|
| `effect` | Effect-TS runtime |
| `@reventlessdev/reventless-aws` | AWS adapters |
| `@reventlessdev/reventless-core` | Core framework |
| `graphql` | GraphQL parser |

The layer is published to AWS Lambda via CI/CD and attached to all Lambda functions. This avoids duplicating 13+ MB of dependencies in every handler's zip archive.

### Handler Consolidation Strategies

Runtime builders consolidate multiple components into fewer Lambdas:

| Lambda Name | Contents | Runtime Builder |
|---|---|---|
| `AllAggregatesCmdHandler` | All aggregate handlers | `AggregateRuntime_Builder_Single` |
| `AllReadModels` | All read model projections | `EventCollectorRuntime_Builder_Single` |
| `AllStateViewSlices` | All DCB state view slice handlers | `StateViewSliceRuntime_Builder_Single` |
| `AllAutomationSlices` | All automation + outbound translation handlers | `AutomationSliceRuntime_Builder_Single` |
| `*CmdTopic` | Per-aggregate/EP command topic handler | `ExtensionPointRuntime_Builder_PerExtensionPoint` |
| `*Heartbeat` | Plugin heartbeat handler | `PluginRuntime_Builder` |
| `<Plugin>DcbCmdHandler` / `<Plugin>DcbAsyncCmdHandler` | DCB command topic composite handler (per plugin, async created only if any `@@reventless.async` slice exists) | `PluginRuntime_Builder` |

Each consolidated Lambda receives events from multiple DynamoDB Streams and routes them to the correct handler based on the source ARN (passed via environment variables).

---

## 5. Plugin File Conventions

### Package Structure

Each plugin in the hybrid example has two packages:

```
ordering/                          # Platform-agnostic (Layer 1+2)
├── src/
│   ├── Order/                     # Domain specs (Layer 1)
│   │   ├── Aggregate/
│   │   ├── StateChangeSlice/
│   │   └── StateViewSlice/
│   └── Plugin.res                 # Auto-generated (Layer 2)
├── tests/
│   └── E2E/OrderingE2ETest.res    # Uses local platform
└── package.json                   # deps: reventless-spec, reventless-infra

ordering-aws/                      # AWS deployment (Layer 3)
├── src/
│   ├── Plugin.res                 # AWS plugin variant (Layer 3)
│   ├── Main.res                   # Composition root (auto-generated)
│   └── index.mjs                  # JS entry point
└── package.json                   # deps: reventless-aws, ordering (private)
```

### The `Plugin.res` Pattern

The `-aws` package's `Plugin.res` is auto-generated and is just a thin wrapper that picks the AWS Platform and forwards to the standard plugin's `Make` functor. All component declarations live in the standard plugin (`ordering/src/Plugin.res`); the AWS variant adds nothing of its own:

```rescript
// AUTO-GENERATED — ordering-aws/src/Plugin.res
@val external uiBundleUrl: option<string> = "process.env.ORDERING_UI_BUNDLE_URL"

module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  module Composition = OrderingPlugin.Plugin.Make(Platform)
  let make = () => Composition.make(~uiBundleUrl?)
}
```

The Lambda registration happens inside `Composition = OrderingPlugin.Plugin.Make(Platform)` when the AWS Platform's `Aggregate.Make` / `ReadModel.Make` / etc. functors run on each aggregate, read model, and slice. None of this is visible at the wrapper layer.

### The `index.mjs` Entry Point

DCB components require configuration to be registered **before** ReScript modules initialize (ReScript's dead code elimination removes module-level side-effect calls inside constrained functors). The `index.mjs` file re-exports the generated `Main.res.mjs` as the default:

```javascript
// ordering-aws/src/index.mjs
export { default } from "./Main.res.mjs";
```

The plugin name is auto-registered by `Plugin_Builder.make` — no manual `registerDcbConfig` call is needed.

### The `Main.res` Composition Root

`Main.res` is **auto-generated** by the generator (`--aws` mode). Do not edit it manually — run `npm run generate` to regenerate.

```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
// Ordering plugin — AWS deployment.

module Platform = ReventlessAws.Platform.Make()
module Ordering = Plugin.Make(Platform)

let default = Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~plugin=module(Ordering),
)
```

`deployPlugin` returns the Pulumi stack outputs dict (`dict<Pulumi.Output.t<JSON.t>>`). Assigning it to `let default` makes it the ESM module export that Pulumi reads as the stack's outputs.

---

## 6. Local Platform for Testing

### How It Works

The local platform replaces all AWS services with in-process equivalents built on `LocalBus`:

```rescript
module Platform = ReventlessLocal.Platform.Make()
module Ordering = OrderingPlugin.Plugin.Make(Platform)  // uses the platform-agnostic plugin

Platform.makePlatform(
  ~version="test",
  ~plugins=[module(Ordering)],
)
```

`LocalBus` is a central event/command routing hub with:
- **Event hubs** — per-topic PubSub for event fan-out
- **Command handlers** — per-channel command dispatch
- **QueryDb registry** — per-read-model in-memory storage
- **Event log replay** — aggregate and DCB event history

### Pulumi Mock Mode

The local platform activates Pulumi mock mode via `TestRunner.setup()`. This makes all `Pulumi.Output.t` values resolve synchronously, allowing tests to await infrastructure wiring:

```rescript
// In test setup
let _ = ReventlessLocal.TestRunner.setup()

// Resolve an Output to get its value
let ops = await component->Component.operations->ReventlessLocal.TestRunner.resolve
```

### E2E Test Pattern

```rescript
// CatalogE2ETest.res
describe("Catalog E2E", () => {
  let _ = ReventlessLocal.TestRunner.setup()

  module Bus = ReventlessLocal.LocalBus.Make()
  module Platform = ReventlessLocal.Platform.MakeWithConfig({
    let silent = true
    let splitApi = false
    let cloner = false
  })
  module Catalog = CatalogPlugin.Plugin.Make(Platform)

  // Force async Output chains to resolve before tests run
  beforeAllAsync(async () => {
    let _ = await eventLog->Component.operations->TestRunner.resolve
  })

  testPromise("AddProduct creates event", async () => {
    // ... dispatch command, assert events
  })
})
```

### Key Testing Conventions

- **`beforeAllAsync`** must resolve Output chains before the first test (handler registration is async)
- **Topic names** follow the pattern: `Spec.name ++ ComponentType.toName(suffix)` (e.g., `"CatalogEventTopic"`)
- The auto-generated `Plugin.res` (Layer 2) is used for tests — it goes through `Platform.T` and works with in-memory
- `Plugin.res` files in `-aws` packages are never tested with in-memory (they import `ReventlessAws` directly)

---

## 7. DCB Slice Lambda Creation: The Hook Mechanism

DCB (Dynamic Consistency Boundary) slices use a hook-based mechanism to bridge the gap between platform-agnostic slice creation (via `Platform.T`) and AWS-specific Lambda creation.

### The Flow

```
1. ordering-aws/src/Plugin.res creates slices via Platform.T:
   │  module OrdersView = Platform.StateViewSlice.Make(OrdersViewSpec)
   │  (internally registers handler spec in StateViewSliceRuntime_Builder_Single)
   │
2. Dcb_Builder.construct() calls .make() on each slice:
   │  → creates DynamoDB table, QueryDb, AppSync resolvers
   │  → runtime builder accumulates handler specs (no Lambda yet)
   │
3. Dcb_Builder fires onDcbSlicesCreated hook
   │
4. AWS Platform's hook implementation calls finish():
   │  StateViewSliceRuntime_Builder_Single.finishWithDcbEventLog(dcbEventLog)
   │  AutomationSliceRuntime_Builder_Single.finish()
   │  → creates "AllStateViewSlices" and "AllAutomationSlices" Lambdas
```

### Platform Hooks for DCB

The AWS Platform registers four hooks that extract infrastructure IDs for Lambda handler configuration:

| Hook | Fires When | AWS Action |
|---|---|---|
| `onDcbEventLogCreated` | DcbEventLog component created | Extracts DynamoDB table name for DCB CommandTopic Lambda handler |
| `onDcbCommandTopicCreated` | DCB CommandTopic created | Extracts SQS queue URL for AutomationSlice/OutboundTranslationSlice |
| `onDcbSlicesCreated` | All DCB slices registered | Calls `finish()` on runtime builders to create Lambdas |
| `onHeartbeatEpChannelAvailable` | Heartbeat EP channel ready | Extracts SQS queue URL for heartbeat Lambda handler |

---

## 8. Adapter Comparison Table

| Adapter | In-Memory Module | AWS Module |
|---|---|---|
| Runtime environment | `LocalRuntimeEnvironment` | `RuntimeEnvironment.Lambda` |
| Command topic channel | `LocalCommandTopicChannel` | `CommandTopicChannel.SQS_FIFO` |
| Event topic publisher | `LocalEventTopicPublisher` | `EventTopicPublisher.DynamoDbStream` |
| Event log storage | `EventLogStorage_InMemory` | `EventLogStorage.DynamoDbStream` |
| Event collector channel | `LocalEventCollectorChannel` | `EventCollectorChannel.DynamoDbStream` |
| QueryDb storage | `QueryDbStorage_InMemory` | `QueryDbStorage.DynamoDb` |
| QueryDb resolvers | `QueryDbResolvers_GraphQL` | `QueryDbResolvers.AppSync` |
| DCB event log storage | `DcbEventLogStorage_InMemory` | `DcbEventLogStorage.DynamoDb` |
| Command generator resolvers | `CommandGeneratorResolvers_GraphQL` | `CommandGeneratorResolvers.AppSync` |

The core builders (`Aggregate_Builder`, `ReadModel_Builder`, `StateViewSlice_Builder`, etc.) in `reventless-core` are parameterized by these adapters via functors. The platform packages (`reventless-aws`, `reventless-local`) instantiate the core builders with their concrete adapters.

---

## 9. Key Lessons

1. **ReScript DCE is aggressive.** Module-level `let () = fn()` calls inside constrained functors are removed. Side-effect registration for Lambda handlers must happen in plain JS entry points (`index.mjs`) or through values that are consumed.

2. **`CallbackFunction` is broken with Effect-TS.** Any Lambda handler that transitively uses `Effect.runPromise` (which is all of them) fails Pulumi's closure serializer. There is no workaround short of using code assets.

3. **Handler registration requires module paths.** The `specModulePath`, `behaviorModulePath`, etc. are resolved at deploy time and embedded in the generated entry point code. The Lambda handler imports these modules at runtime.

4. **`finish()` timing matters.** Runtime builders accumulate specs during `forEventCollector` / `registerXxx` calls and create the Lambda only when `finish()` is called. This must happen after all components have registered but before Pulumi's deployment graph is finalized.

5. **`Plugin.res` in `-aws` packages is a thin wrapper.** It delegates to the standard plugin's `Make` functor and only differs in two ways: it constrains `Platform.api` / `Platform.role` to the AppSync types, and it provides an env-var-driven `make: unit => component` that satisfies `PluginMaker`. All component declarations live in the standard `Plugin.res`, which is the single source of truth for in-memory tests and AWS deployment alike.

6. **`Platform.T` is the only entry point for component creation.** `Aggregate.Make`, `ReadModel.Make`, `ExtensionPoint.Make`, `StateChangeSlice.Make`, `StateViewSlice.Make`, `AutomationSlice.Make`, `OutboundTranslationSlice.Make`, and `InboundTranslationSlice.Make` are all platform-provided. The AWS Platform's implementations register Lambda handlers internally — eagerly for aggregates/readmodels/EPs/tasks, deferred via the `onDcbSlicesCreated` hook for DCB slices. Plugin code never names the underlying AWS builders.

---

## 10. Tuning the command-handler Lambdas

`Platform.MakeWithConfig` accepts a `commandHandlerConfig` record that lets you
tune the four command-handler Lambdas independently:

- `AllAggregatesCmdHandler` — sync aggregates, platform-wide
- `AllAggregatesAsyncCmdHandler` — async aggregates (opted in via `@@reventless.async`), platform-wide
- `<Plugin>DcbCmdHandler` — sync DCB slices, per plugin
- `<Plugin>DcbAsyncCmdHandler` — async DCB slices, per plugin

Every field on the inner `commandHandlerConfig` record is optional. Unset fields
fall back to the framework defaults exposed as
`Reventless.Runtime.CommandHandlerDefaults` (1024 MB memory, 30 s timeout,
batch size 10, 512 MB `/tmp`).

`logRetentionDays` and `logLevel` are **not** flat defaults — they are resolved
per environment tier (see [§11](#11-log-retention-and-levels-per-environment)).
When unset, retention and log level follow the stack's tier rather than a fixed
value; setting either field pins it for that handler and overrides the tier.

```rescript
module Platform = ReventlessAws.Platform.MakeWithConfig({
  let splitApi = true
  let cloner = false
  let commandHandlerConfig: ReventlessCore.Runtime.commandHandlerConfigs = {
    aggregates: {
      async: {memorySize: 2048, timeout: 300, sqsBatchSize: 50},
    },
    stateChanges: {
      async: {memorySize: 2048, reservedConcurrency: 50},
    },
  }
})
```

In the example above, only `AllAggregatesAsyncCmdHandler` and `<Plugin>DcbAsyncCmdHandler`
diverge from defaults — the sync Lambdas (and any branch you omit entirely)
ship with the framework-default Lambda config.

Compose against the defaults to derive scaled values without hard-coding them:

```rescript
open Reventless.Runtime

let commandHandlerConfig: commandHandlerConfigs = {
  aggregates: {
    async: {memorySize: CommandHandlerDefaults.memorySize * 2},
  },
}
```

| Field | AWS Lambda mapping |
|---|---|
| `memorySize` | `MemorySize` (MB; 128–10240) |
| `timeout` | `Timeout` (seconds; 1–900) |
| `reservedConcurrency` | `ReservedConcurrentExecutions` |
| `sqsBatchSize` | SQS event-source mapping `batchSize` |
| `ephemeralStorageMb` | `EphemeralStorage.size` (`/tmp` size, MB) |
| `logRetentionDays` | A dedicated `CloudWatch.LogGroup` with `retentionInDays` (overrides the environment tier) |
| `logLevel` | `LOG_LEVEL` env var — the logger's minimum level (overrides the environment tier) |
| `envVars` | Extra `environment.variables`, layered under framework-set keys |

The local platform accepts the same record for type parity but ignores
Lambda-specific knobs; only the call-path that creates AWS infrastructure
honors them.

`Platform.Make()` keeps the default behavior — an empty `commandHandlerConfig`
that leaves every Lambda on framework defaults.

## 11. Log retention and levels per environment

Retention and log level are **not** fixed defaults — they are tiered by Pulumi
stack, reusing the same prod allow-list (`hostUiProdStacks`) that names the
host-shell domain and store layout. `Util_LogRetention` (in `reventless-aws`)
holds the pure tier functions:

| Tier | Stacks | Retention | `LOG_LEVEL` |
|------|--------|-----------|-------------|
| prod | `prod`, `main` | 365 days | `info` |
| staging | `beta` | 30 days | `info` |
| dev | `alpha`, and any unlisted stack | 7 days | `debug` |
| ephemeral | `pr-*` | 3 days | `debug` |

Retention and level pull in opposite directions between the two worlds — prod is
quiet and long-lived, the dev stacks are loud and short-lived — which is why a
single global setting cannot serve both.

- **`LOG_LEVEL`** is defaulted per tier for **every** Lambda when nothing pins it
  (a caller env var or `commandHandlerConfig.logLevel` wins). No migration
  hazard: it is only an env var.
- **Managed log groups** (with tiered `retentionInDays`) are created for **every**
  stack by default (`Util_LogRetention.managesLogGroup`).
- **A Lambda's group is created before the function that writes to it.** The
  deploy names the group itself — `/aws/lambda/<stack>-<component>` — and hands
  it to the function through Lambda's Advanced Logging Controls
  (`loggingConfig.logGroup`). Two consequences worth knowing:
  - The deploy cannot lose a race to the Lambda service. A function configured
    with a log group has somewhere to write from its first invocation, so it
    never triggers the lazy auto-create of `/aws/lambda/<physical name>` that a
    group created *after* its function would have had to beat. That race was not
    survivable on retry: the auto-created group persists, so every later attempt
    failed `ResourceAlreadyExists` identically.
  - The name is stable across replacement. It carries no Pulumi `-<7hex>`
    physical-name suffix, so replacing a function keeps its group instead of
    stranding the old one as an orphan nothing tears down.

  A stack that ran an earlier version keeps its old auto-created groups. They are
  no longer written to and no longer managed, and they have no retention — delete
  them once the first deploy on the new naming has landed.
- **AppSync groups are not covered by that ordering.** An AppSync API's group name
  (`/aws/appsync/apis/<id>`) is fixed by a server-assigned id and the service has
  no "write here" knob, so its group can only be created after the API exists.
- **Overrides:** the Pulumi config keys `logRetentionDays` (an integer; `0` =
  never expire) and `logLevel` override the tier for a whole stack;
  `commandHandlerConfig.logRetentionDays` / `logLevel` override it for a single
  command handler. `unmanagedLogGroupStacks` (CSV of stack names) keeps the named
  stacks on Lambda/AppSync auto-created groups.

  `unmanagedLogGroupStacks` is only safe on a stack that has adopted **nothing**.
  It makes the program stop *declaring* log groups, which on a stack that already
  holds some in state reads as removed-from-the-program — so the next deploy
  deletes those groups, together with their retention, their tags and any metric
  filters attached to them.
