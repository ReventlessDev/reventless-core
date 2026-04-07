# Lambda Deployment Architecture

This guide explains how Reventless deploys Lambda handlers on AWS, how this relates to the **in-memory** and **AWS** platforms, and the conventions for writing platform-agnostic vs. AWS-specific plugin code.

For related guides, see:
- [Application Development Layers](application-development-layers.md) — the three-layer architecture
- [Platform and Plugin Guide](platform-and-plugin-guide.md) — creating platforms and plugins
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

| | In-Memory | AWS |
|---|---|---|
| **Package** | `reventless-in-memory` | `reventless-aws` |
| **`type api`** | `unit` | `Types.AppSync.api` |
| **`type role`** | `unit` | `Types.AppSync.role` |
| **Event storage** | In-memory dict | DynamoDB |
| **Command dispatch** | In-memory bus | SQS FIFO |
| **Event fan-out** | In-memory bus | DynamoDB Streams |
| **Query storage** | In-memory dict | DynamoDB + GSI |
| **Handler runtime** | Deferred promise | Lambda function |
| **API** | GraphQL Yoga (local) | AppSync |
| **Used for** | Tests, local dev | Production deployment |

Plugin code that uses only `Platform.T` works identically on both platforms. The platform determines the concrete adapters.

### Three Development Layers

```
Layer 1 — Domain Specification    (deps: reventless-spec)
Layer 2 — Plugin Assembly         (deps: reventless-spec + reventless-infra)
Layer 3 — Composition Root        (deps: reventless-infra + reventless-aws or reventless-in-memory)
```

Layer 2 is where plugin functors live. They accept a `Platform: ReventlessInfra.Platform.T` parameter and use `Platform.Aggregate.Make`, `Platform.ReadModel.Make`, etc. This is platform-agnostic code.

Layer 3 instantiates a concrete platform (`ReventlessAws.Platform.Make()` or `ReventlessInMemory.Platform.Make()`) and passes it to the plugin functor. This is the only layer that names a specific provider.

### Where AWS Builders Fit

Aggregates, ReadModels, and ExtensionPoints require AWS-specific builders that register Lambda handlers. These live in Layer 3, in `_Aws.res` files.

```
┌─────────────────────────────────────────────────────┐
│  CatalogPlugin.res (Layer 2 — platform-agnostic)    │
│    Platform.Aggregate.Make(Category, ...)           │
│    Platform.StateViewSlice.Make(ProductsView)       │
└────────────────────┬────────────────────────────────┘
                     │ used by both:
    ┌────────────────┼────────────────────┐
    │                │                    │
    ▼                ▼                    ▼
  Tests          In-Memory Dev       CatalogPlugin_Aws.res
  (in-memory)    (GraphQL Yoga)      (Layer 3 — AWS-specific)
                                       ReventlessAws.Aggregate_Builder_Single.Make(...)
                                       Platform.StateViewSlice.Make(ProductsView)  ← still via Platform
```

---

## 3. AWS Plugin Variants: `_Aws.res` Files

### Platform-Agnostic (via `Platform.T`)

```rescript
// Layer 2 — works with any platform
module Make = (Platform: ReventlessInfra.Platform.T) => {
  module CategoryAggregate = Platform.Aggregate.Make(
    Category, CategoryBehavior, NoEventMappings.Make(Category),
  )
}
```

- Works with in-memory (for tests) and AWS (for production)
- `Platform.Aggregate.Make` on AWS satisfies the type but registers **no Lambda entry point**
- For a working AWS aggregate Lambda, use the AWS builder directly in a `_Aws.res` variant

### AWS-Specific (direct AWS builders)

```rescript
// Layer 3 — CatalogPlugin_Aws.res
module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  // Direct AWS builder — registers Lambda handler
  module CategoryAggregate = ReventlessAws.Aggregate_Builder_Single.Make(
    Category, CategoryBehavior, NoEventMappings.Make(Category),
  )

  // Via Platform — DCB slices get Lambdas through the hook mechanism
  module OrdersViewSlice = Platform.StateViewSlice.Make(OrdersViewSpec)
}
```

- Handler code is generated as a JS source string, bundled with esbuild
- Infrastructure references passed as Lambda environment variables
- **AWS only** — no equivalent needed for in-memory

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

### Which Components Use AWS Builders vs. `Platform.T`

| Component | Uses | Reason |
|---|---|---|
| Aggregate | AWS builder directly | Creates Lambda handler |
| ReadModel | AWS builder directly | Creates Lambda handler |
| ExtensionPoint | AWS builder directly | Creates Lambda handler |
| Extension | `Platform.T` | No Lambda handler (maps events between EPs) |
| StateChangeSlice | `Platform.T` | No own Lambda (events go through DCB CommandTopic Lambda) |
| StateViewSlice | `Platform.T` | Lambda created by `finish()` via platform hook |
| AutomationSlice | `Platform.T` | Lambda created by `finish()` via platform hook |
| OutboundTranslationSlice | `Platform.T` | Lambda created by `finish()` via platform hook |
| InboundTranslationSlice | `Platform.T` | Lambda created by `finish()` via platform hook |
| DcbEventLog | `Platform.T` | Infrastructure only (DynamoDB table) |
| Counter | `Platform.T` | Created inside Platform functor |
| Task | AWS builder directly | Creates Lambda handler |

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
| `AllAggregates` | All aggregate handlers | `AggregateRuntime_Builder_Single` |
| `AllReadModels` | All read model projections | `EventCollectorRuntime_Builder_Single` |
| `AllStateViewSlices` | All DCB state view slice handlers | `StateViewSliceRuntime_Builder_Single` |
| `AllAutomationSlices` | All automation + outbound translation handlers | `AutomationSliceRuntime_Builder_Single` |
| `*CmdTopic` | Per-aggregate/EP command topic handler | `ExtensionPointRuntime_Builder_PerExtensionPoint` |
| `*Heartbeat` | Plugin heartbeat handler | `PluginRuntime_Builder` |
| `*-dcb-command-topicCmdTopic` | DCB command topic composite handler | `PluginRuntime_Builder` |

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
│   └── Plugin/
│       └── OrderingPlugin.res     # Plugin functor (Layer 2)
├── tests/
│   └── E2E/OrderingE2ETest.res    # Uses in-memory platform
└── package.json                   # deps: reventless-spec, reventless-infra

ordering-aws/                      # AWS deployment (Layer 3)
├── src/
│   ├── OrderingPlugin_Aws.res     # AWS plugin variant
│   ├── Main.res                   # Composition root
│   └── index.mjs                  # JS entry point (DCB config registration)
└── package.json                   # deps: reventless-aws, ordering (private)
```

### The `_Aws.res` Pattern

A `_Aws.res` file mirrors the platform-agnostic plugin but substitutes direct AWS builders for components that need Lambda handlers:

```rescript
// OrderingPlugin_Aws.res
module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  // Direct AWS builder — registers Lambda handler
  module CustomerAggregate = ReventlessAws.Aggregate_Builder_Single.Make(
    OrderingPlugin.Customer, OrderingPlugin.CustomerBehavior,
    ReventlessInfra.NoEventMappings.Make(OrderingPlugin.Customer),
  )

  // Via Platform — infrastructure only (no own Lambda)
  module PlaceOrderSlice = Platform.StateChangeSlice.Make(OrderingPlugin.PlaceOrder)

  // Via Platform — Lambda created via onDcbSlicesCreated hook + finish()
  module OrdersViewSlice = Platform.StateViewSlice.Make(OrderingPlugin.OrdersView)
  module AutoShipOrderSlice = Platform.AutomationSlice.Make(OrderingPlugin.AutoShipOrder)

  // Assembly is identical to the platform-agnostic version
  let make = () =>
    Platform.Plugin.make(~name="Ordering", ...)
}
```

### The `index.mjs` Entry Point

DCB components require configuration to be registered **before** ReScript modules initialize (ReScript's dead code elimination removes module-level side-effect calls inside constrained functors). The `index.mjs` file handles this:

```javascript
// ordering-aws/src/index.mjs
import { registerDcbConfig } from
  "@reventlessdev/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res.mjs";
import { resolveModule } from
  "@reventlessdev/reventless-aws/src/util/Util_Bundle.res.mjs";

const pkg = "@reventlessdev/online-shop-hybrid-ordering/src";

// Register BEFORE Main.res.mjs loads — plain JS side effects are never DCE'd
registerDcbConfig("Ordering", undefined, [
  resolveModule(pkg + "/Order/StateChangeSlice/PlaceOrder.res.mjs"),
  resolveModule(pkg + "/Order/StateChangeSlice/ShipOrder.res.mjs"),
  resolveModule(pkg + "/Order/StateChangeSlice/CancelOrder.res.mjs"),
], undefined);

export { default } from "./Main.res.mjs";
```

### The `Main.res` Composition Root

```rescript
// ordering-aws/src/Main.res
module Platform = ReventlessAws.Platform.Make()
module Ordering = OrderingPlugin_Aws.Make(Platform)

Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~plugin=module(Ordering),
)

let default = Pulumi.Pulumi.getOutputs()
```

---

## 6. In-Memory Platform for Testing

### How It Works

The in-memory platform replaces all AWS services with in-process equivalents built on `InMemory_Bus`:

```rescript
module Platform = ReventlessInMemory.Platform.Make()
module Ordering = OrderingPlugin.Make(Platform)  // uses the platform-agnostic plugin

Platform.makePlatform(
  ~version="test",
  ~plugins=[module(Ordering)],
)
```

`InMemory_Bus` is a central event/command routing hub with:
- **Event hubs** — per-topic PubSub for event fan-out
- **Command handlers** — per-channel command dispatch
- **QueryDb registry** — per-read-model in-memory storage
- **Event log replay** — aggregate and DCB event history

### Pulumi Mock Mode

The in-memory platform activates Pulumi mock mode via `TestRunner.setup()`. This makes all `Pulumi.Output.t` values resolve synchronously, allowing tests to await infrastructure wiring:

```rescript
// In test setup
let _ = ReventlessInMemory.TestRunner.setup()

// Resolve an Output to get its value
let ops = await component->Component.operations->ReventlessInMemory.TestRunner.resolve
```

### E2E Test Pattern

```rescript
// CatalogE2ETest.res
describe("Catalog E2E", () => {
  let _ = ReventlessInMemory.TestRunner.setup()

  module Bus = ReventlessInMemory.InMemory_Bus.Make()
  module Platform = ReventlessInMemory.Platform.MakeWithConfig({
    let silent = true
    let splitApi = false
    let cloner = false
  })
  module Catalog = CatalogPlugin.Make(Platform)

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
- Platform-agnostic plugin files (`CatalogPlugin.res`) are used for tests — they go through `Platform.T` and work with in-memory
- `_Aws.res` plugin files are never tested with in-memory (they import `ReventlessAws` directly)

---

## 7. DCB Slice Lambda Creation: The Hook Mechanism

DCB (Dynamic Consistency Boundary) slices use a hook-based mechanism to bridge the gap between platform-agnostic slice creation (via `Platform.T`) and AWS-specific Lambda creation.

### The Flow

```
1. Plugin_Aws.res creates slices via Platform.T:
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
| Runtime environment | `RuntimeEnvironment_InMemory` | `RuntimeEnvironment.Lambda` |
| Command topic channel | `CommandTopicChannel_InMemory` | `CommandTopicChannel.SQS_FIFO` |
| Event topic publisher | `EventTopicPublisher_InMemory` | `EventTopicPublisher.DynamoDbStream` |
| Event log storage | `EventLogStorage_InMemory` | `EventLogStorage.DynamoDbStream` |
| Event collector channel | `EventCollectorChannel_InMemory` | `EventCollectorChannel.DynamoDbStream` |
| QueryDb storage | `QueryDbStorage_InMemory` | `QueryDbStorage.DynamoDb` |
| QueryDb resolvers | `QueryDbResolvers_GraphQL` | `QueryDbResolvers.AppSync` |
| DCB event log storage | `DcbEventLogStorage_InMemory` | `DcbEventLogStorage.DynamoDb` |
| Command generator resolvers | `CommandGeneratorResolvers_GraphQL` | `CommandGeneratorResolvers.AppSync` |

The core builders (`Aggregate_Builder`, `ReadModel_Builder`, `StateViewSlice_Builder`, etc.) in `reventless-core` are parameterized by these adapters via functors. The platform packages (`reventless-aws`, `reventless-in-memory`) instantiate the core builders with their concrete adapters.

---

## 9. Key Lessons

1. **ReScript DCE is aggressive.** Module-level `let () = fn()` calls inside constrained functors are removed. Side-effect registration for Lambda handlers must happen in plain JS entry points (`index.mjs`) or through values that are consumed.

2. **`CallbackFunction` is broken with Effect-TS.** Any Lambda handler that transitively uses `Effect.runPromise` (which is all of them) fails Pulumi's closure serializer. There is no workaround short of using code assets.

3. **Handler registration requires module paths.** The `specModulePath`, `behaviorModulePath`, etc. are resolved at deploy time and embedded in the generated entry point code. The Lambda handler imports these modules at runtime.

4. **`finish()` timing matters.** Runtime builders accumulate specs during `forEventCollector` / `registerXxx` calls and create the Lambda only when `finish()` is called. This must happen after all components have registered but before Pulumi's deployment graph is finalized.

5. **`_Aws.res` files are AWS-specific.** They mirror the platform-agnostic plugin but substitute direct AWS builders. They import `ReventlessAws` directly and cannot be tested with the in-memory platform. The platform-agnostic plugin file remains the source of truth for business logic and is used for in-memory testing.

6. **`Platform.T` uses the same builders for DCB slices.** `StateViewSlice.Make`, `AutomationSlice.Make`, and `OutboundTranslationSlice.Make` all register handler specs when called from `_Aws.res` files. The Lambda is created later via `finish()` called by the `onDcbSlicesCreated` hook. No separate AWS builder is needed for slice types.
