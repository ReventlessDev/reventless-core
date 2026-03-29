# Plan: Compiled Entry Points — Eliminate Code Generation and esbuild (Alternative D)

**Analysis**: [docs/analysis/esbuild-bundling-process.md](../analysis/esbuild-bundling-process.md)

## Goal

Replace the current code-string-generation + esbuild pipeline with **compiled ReScript entry point modules** that live in the Lambda Layer. This eliminates ~2,570 lines of hand-written JavaScript, removes esbuild as a deploy-time dependency, and makes framework changes compiler-verified instead of silently breaking at runtime.

## Background

The current pipeline generates unique JavaScript code strings for each Lambda at deploy time, writes them to temp files, and runs esbuild to bundle them. The generated code contains hardcoded import paths, export names, and functor call patterns — all unverifiable by the compiler.

Alternative D replaces this with:
1. **Compiled ReScript entry points** per component type (in the Layer) — real functor calls, compiler-checked
2. **JSON config via env vars** — per-Lambda differences are data, not code
3. **Dynamic `import()`** for user modules (Spec, Behavior) at cold start
4. **Static one-line re-export** as the Lambda code asset — no generation, no esbuild

## Architecture

```
┌─ Lambda Code Asset ─────────────────────────────┐
│ index.mjs (one line, static):                    │
│ export { handler } from                          │
│   "@reventlessdev/reventless-aws/.../             │
│    AggregateEntryPoint.res.mjs";                 │
└──────────────────────────────────────────────────┘

┌─ Lambda Environment Variables ──────────────────┐
│ HANDLER_CONFIG = {                               │
│   "handlers": [{                                 │
│     "specModule": "@.../Category.res.mjs",       │
│     "behaviorModule": "@.../CategoryBehavior...",│
│     "eventLogTable": "MyTable-abc123",           │
│     "queueUrl": "https://sqs.../queue",          │
│     "queueArn": "arn:aws:sqs:..."                │
│   }]                                             │
│ }                                                │
└──────────────────────────────────────────────────┘

┌─ Lambda Layer (/opt/nodejs/node_modules/) ──────┐
│ @reventlessdev/reventless-aws/                   │
│   src/adapter/Runtime/                           │
│     AggregateEntryPoint.res.mjs  ← NEW          │
│     AggregateHandlerFactory.mjs  ← DELETED      │
│     ...                                          │
│ @reventlessdev/reventless-core/                  │
│   src/components/Aggregate/Aggregate_Callback... │
│   src/components/EventLog/EventLog_Operations... │
│ effect/, sury/, @rescript/runtime, ...           │
│                                                  │
│ User plugin packages (if included in layer):     │
│ @reventlessdev/online-shop-hybrid-catalog/       │
│   src/Category/Aggregate/Category.res.mjs        │
│   src/Category/Aggregate/CategoryBehavior.res.mjs│
└──────────────────────────────────────────────────┘
```

## Prerequisites: Pulumi Transitive Import Analysis ✅

All 10 runtime functors are **clean** — none have any transitive `@pulumi/pulumi` or `@pulumi/aws` imports. The existing `_Callback`/`_Operations` separation from `_Builder` modules already correctly isolates Pulumi imports to deploy-time code only.

| Functor | Pulumi? | External deps |
|---------|---------|---------------|
| `Aggregate_Callback.Make` | NO | effect, sury, uuid |
| `CommandTopic_Callback.Make` | NO | effect, sury, uuid |
| `EventLog_Operations.Make` | NO | effect, sury, uuid, rescript-effect |
| `ReadModel_Callback.Make` | NO | effect, sury, uuid, reventless-infra, rescript-effect |
| `StateChangeSlice_Callback.Make` | NO | effect, sury, rescript-effect, DcbTag |
| `DcbEventLog_Operations.Make` | NO | effect, sury, uuid, rescript-effect, DcbTag |
| `ExtensionPoint_Operations.Make` | NO | effect, sury, uuid, rescript-effect |
| `SideEffectHandler_Callback.Make` | NO | effect, sury, uuid, rescript-effect |
| `Counter_Callback.Make` | NO | effect, sury, uuid |
| `EventMapper_Callback.Make` | NO | effect, sury, uuid, rescript-effect |

**Consequence**: Step 3 (split framework modules) is **not needed**. This simplifies the plan — we can proceed directly from Step 2 to Step 4.

## Step 1: Eliminate application `index.mjs` files ✅

Already implemented. Moved `registerDcbConfig` + `resolveModule` calls into `Main.res`. Updated `Pulumi.yaml` to point to `Main.res.mjs`. Deleted `index.mjs` files.

**Files modified**:
- `examples/online-shop-hybrid/catalog-aws/src/Main.res`
- `examples/online-shop-hybrid/ordering-aws/src/Main.res`
- `examples/online-shop-hybrid/platform-aws/Pulumi.yaml`
- `examples/online-shop-hybrid/catalog-aws/Pulumi.yaml`
- `examples/online-shop-hybrid/ordering-aws/Pulumi.yaml`

**Files deleted**:
- `examples/online-shop-hybrid/platform-aws/src/index.mjs`
- `examples/online-shop-hybrid/catalog-aws/src/index.mjs`
- `examples/online-shop-hybrid/ordering-aws/src/index.mjs`

**Verification**:
- [x] Build with zero warnings
- [ ] Deploy platform-aws stack
- [ ] Deploy catalog-aws and ordering-aws stacks

## Step 2: Decide user module packaging strategy ✅

**Decision: Option A — Copy user npm packages into the Lambda code asset via AssetArchive.**

The user's business logic (Spec, Behavior, Mappings) must be available at Lambda runtime. Currently esbuild bundles them into the Lambda code asset. With Alternative D, user packages are copied directly into the code asset's `node_modules/` directory — no esbuild, no code generation, no extra layers.

**Options evaluated:**

| Option | Verdict | Reason |
|--------|---------|--------|
| A. Multi-file AssetArchive | **CHOSEN** | No build step, no layer rebuild, simple file copy |
| B. User package in framework Layer | Rejected | Couples user code releases to framework layer — breaks deployment model |
| C. Separate user Layer | Rejected | Overkill — adds second layer build pipeline for marginal benefit |
| D. Keep esbuild for user modules only | Rejected | Defeats the goal — still needs esbuild + code generation |

**Lambda code asset structure:**
```
/var/task/
├── index.mjs                          # one-line re-export from Layer entry point
└── node_modules/
    └── @reventlessdev/
        └── online-shop-hybrid-catalog/
            └── src/Category/Aggregate/
                ├── Category.res.mjs
                └── CategoryBehavior.res.mjs
```

**Deploy-time flow:**
1. Extract package name from user module path (e.g., `@reventlessdev/online-shop-hybrid-catalog`)
2. Find the package root via `resolveModule` / `require.resolve`
3. Walk the package directory and add **only runtime-essential files** to Pulumi `AssetArchive` under `node_modules/<pkg>/`:
   - `*.res.mjs` — compiled ReScript modules (the actual runtime code)
   - `package.json` — required for ESM module resolution
   - **Exclude everything else**: `lib/`, `tests/`, `__mocks__/`, `*.res`, `*.resi`, `CHANGELOG*`, `README*`, `LICENSE*`, `node_modules/`, `.git/`, `rescript.json`, `bsconfig.json`
4. Set `HANDLER_CONFIG` env var with package-specifier paths

**Runtime module resolution:**
- User modules: `import("@reventlessdev/.../Category.res.mjs")` → resolves from `/var/task/node_modules/`
- Framework modules: → resolves from Layer at `/opt/nodejs/node_modules/`

## Step 2b: Eliminate manual module paths with `moduleUrl` ✅

**Problem**: Every user module required a manually-typed npm specifier path in the `-aws` plugin code. These strings duplicated information the compiler already knows.

**Solution**: Each Spec and Behavior module exports `import.meta.url` via a one-liner. The framework derives npm specifiers at deploy time using `getModuleSpecifier(importMetaUrl)`.

**Changes**:
- Added `let moduleUrl: string` to `Aggregate.Spec` and `Behavior.T` module type signatures in reventless-spec
- Added `let moduleUrl: string = %raw(\`import.meta.url\`)` to all implementing modules (~30 files)
- Added `getModuleSpecifier(importMetaUrl)` to `Util_Bundle` — walks up from file path to find `package.json`, derives npm specifier
- Removed `Config` module type from all aggregate builders (`Single`, `NoResolver`, `Micro`, `PerAggregate`)
- Builders derive paths from `Spec.moduleUrl` and `Behavior.moduleUrl` automatically
- Plugin files no longer need manual path strings or `resolveModule` for aggregate paths
- Filtered `createFilteredPackageArchive` includes only `*.res.mjs` + `package.json` (excludes `lib/`, `tests/`, `__mocks__/`, `*.res`, etc.)

## Step 3: Split framework modules (deploy-time vs runtime) — SKIPPED ✅

The prerequisite analysis confirmed all runtime functors (`_Callback.Make`, `_Operations.Make`) are already free of Pulumi imports. The existing architecture already separates deploy-time (`_Builder`) from runtime modules correctly. No module splitting is needed.

## Step 4: Create compiled entry point for Aggregates (proof of concept) ✅

Start with the Aggregate handler — the most common component type.

### 4a. Add utilities to `Util_Bundle` ✅

**`reventless-aws/src/util/Util_Bundle.mjs`** — added three functions:
- `extractPackageName(specifier)` — `"@scope/pkg/src/foo.mjs"` → `"@scope/pkg"` (handles scoped and unscoped)
- `resolvePackageRoot(packageName)` — `require.resolve(pkg + "/package.json")` → `path.dirname(...)` → absolute dir path
- `hashString(str)` — SHA256 → base64 (for `sourceCodeHash`)

**`reventless-aws/src/util/Util_Bundle.res`** — added corresponding `@module` externals.

### 4b. Add `makeFromCodeAsset` to `RuntimeEnvironment_Lambda.res` ✅

New function identical to `makeBundledFromEntryPoint` but takes `~code: Pulumi.Archive.t` and `~sourceCodeHash: string` directly — no esbuild. Reusable by all future entry points in Step 5.

### 4c. Create `AggregateEntryPoint.res` ✅

**`reventless-aws/src/adapter/Runtime/AggregateEntryPoint.res`** — compiled into Layer, runs at Lambda cold start. Replaces both `AggregateHandlerFactory.mjs` and `CommandGeneratorHandlerFactory.mjs`.

**Key design: functor wiring via external bindings.** ReScript functors compile to curried JS functions. `@module` externals keep import paths compiler-verified while allowing dynamic (runtime-loaded) module arguments. Type checking on argument shapes is intentionally lost (all `'a`).

**Object construction pattern:** JS objects with capital-letter keys (`Spec`, `EventTopic`, `EventLog`) can't be expressed as ReScript record literals, so `%raw` helper functions construct them (e.g., `mkEventLogOpsArg`, `mkAggCallbackArg`). Field access on functor results uses `@get` externals (e.g., `getHandleCommands`, `getHandleJsonCommands`).

**Config**: `HANDLER_CONFIG` env var → JSON.parse → typed record:
```rescript
type handlerConfig = {
  specModule: string,    // npm specifier, resolved by import() from /var/task/node_modules/
  behaviorModule: string,
  eventLogTable: string,
  queueUrl: string,
  queueArn: string,
}
type config = { handlers: array<handlerConfig> }
```

**Handler chain** (mirrors `AggregateHandlerFactory.mjs`):
1. `dynamicImport(specModule)`, `dynamicImport(behaviorModule)`
2. `patchSpecId` — spread spec, add `Id: spec.Id || IdString`
3. Raw storage ops from `EventLogStorage_DynamoDb_Runtime.{append, replay, replayStream, appendStream}`
4. No-op event topic (events publish via DynamoDB Stream)
5. `EventLog_Operations.Make(spec)(ops)` → eventLogOps
6. `Aggregate_Callback.Make(spec)(behavior)(ops)` → aggregateCallback
7. `CommandTopic_Callback.Make(spec)(ops)` → commandTopicCallback
8. `handleQueueEvent(queue, commandTopicCallback.handleJsonCommands)`

**Routing** (mirrors generated entry point):
- SQS events → group by `eventSourceARN` → dispatch from `commandTopicHandlers` dict
- AppSync events (`event.command && event.arguments`) → dispatch from `commandGeneratorHandlers` dict
- Effect.provideService(RequestContext.tag, {correlationId}) → Effect.runPromise

**Cold start**: Handlers built eagerly at module top-level as a promise. First invocation awaits the in-progress promise. Opaque types (`cmdTopicHandler`, `cmdGenHandler`) satisfy the value restriction on `initPromise`.

### 4d. Modify `AggregateRuntime_Builder_Single.res` ✅

Replaced `finish()` body:

**Before**: per-handler env vars (`HANDLER_0_TABLE`, etc.) → `generateAggregateEntryPoint()` → `makeBundledFromEntryPoint()` (esbuild)

**After**:
1. Build `HANDLER_CONFIG` as `Pulumi.Output.t<string>` — compose via `Output.all3` + `Output.all` + `Output.apply` over table names, queue URLs, queue ARNs from all registered aggregates
2. Collect unique user package names from spec/behavior paths using `extractPackageName`
3. Resolve package roots using `resolvePackageRoot`
4. Build `AssetArchive`:
   - `"index.mjs"` → `StringAsset` with `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.res.mjs";`
   - `"node_modules/<pkg>"` → `FileArchive(packageRoot)` for each user package
5. Compute `sourceCodeHash` from re-export code + package names
6. Call `RuntimeEnvironment_Lambda.makeFromCodeAsset(~name, ~code, ~sourceCodeHash, ~envVars, ...)`
7. Connect functions and EventCollector wiring — unchanged

### 4e. Change data flow: npm specifiers instead of resolved paths ✅

Removed `resolveModule` wrapping for aggregate paths in both `CatalogPlugin_Aws.res` and `OrderingPlugin_Aws.res`. Other component types keep `resolveModule` until Step 5.

### 4f. Do NOT delete yet ✅

Kept `AggregateHandlerFactory.mjs`, `CommandGeneratorHandlerFactory.mjs`, `generateAggregateEntryPoint`. Other component types still use the factory pattern. Defer deletion to Step 6 cleanup.

### Verification

- [x] `AggregateEntryPoint.res` compiles without Pulumi imports in output: `grep "@pulumi" .../AggregateEntryPoint.res.mjs` returns empty
- [x] Build with zero warnings: `npm run build`
- [x] Deploy platform-aws stack (5 Lambda functions updated)
- [x] Deploy catalog-aws stack (6 updated, 17 old esbuild artifacts deleted)
- [x] Deploy ordering-aws stack (6 updated, 12 old esbuild artifacts deleted)
- [x] Invoke an aggregate command (create Category via SQS) — event log write confirmed (`Added` event in DynamoDB)
- [ ] Verify AppSync CommandGenerator route works
- [x] Cold start: ~1003ms init + 13ms handler (warm: 268ms) — comparable to previous approach

**Note**: Lambda Layer must include `AggregateEntryPoint.res.mjs`. The layer builder downloads from npm registry, so a local workaround is needed until the package is published. The `dynamicImport` function resolves user modules from `/var/task/node_modules/` (absolute path) because ESM import() in the Layer resolves relative to the Layer path, not the code asset.

## Step 5: Migrate remaining component types

After the Aggregate proof of concept validates the approach, migrate each remaining component type. Each follows the same pattern: create a compiled `*EntryPoint.res`, update the builder to use `makeFromCodeAsset` with a static re-export, and add `moduleUrl` to relevant spec types (extending the pattern from Step 2b).

**Completed:**
1. [x] `HeartbeatEntryPoint.res` — simplest, no functor chains, no user modules. Builder updated in `PluginRuntime_Builder.res`.
2. [x] `CommandGeneratorEntryPoint.res` — already handled inside `AggregateEntryPoint.res` (combined routing). No separate entry point needed.

**Remaining (by complexity):**
3. [x] `SideEffectEntryPoint.res` — DynamoDB Stream handler, `SideEffectHandler_Callback.Make`, needs user SideEffect modules. Added `moduleUrl` to `SideEffect.T`. Builder derives paths from `moduleUrl` automatically (no more `Config` module type).
4. [x] `StateViewSliceEntryPoint.res` — DynamoDB Stream handler, inline Effect/Stream chain with `Spec.project()`, needs user spec module. Added `moduleUrl` to `StateViewSlice.Spec`. Removed `Config` module from `Bundled.Make`. Updated Platform type and in-memory Platform.
5. [x] `ReadModelEntryPoint.res` — DynamoDB Stream handler, `ReadModel_Callback.Make(Spec)(Mappings)`, needs user Spec + Mappings modules. Added `moduleUrl` to `ReadModel.Spec` and `Projection.Mappings`. Removed `Config` from `ReadModel_Builder_Single`, `ReadModel_Builder_NoResolver`. Updated Platform, all examples.
6. [x] `AutomationSliceEntryPoint.res` — DynamoDB Stream handler, `AutomationSlice_Callback.Make`, shared with OutboundTranslationSlice. Added `moduleUrl` to `AutomationSlice.Spec` and `OutboundTranslationSlice.Spec`. Uses `callbackType` config field to dispatch between the two callback functors. Removed `BundledSliceConfig` type entirely.
7. [x] `ExtensionPointEntryPoint.res` — SQS handler, maps commands to downstream aggregates. Added `moduleUrl` to `ExtensionMapping.Spec`, `ExtensionMapping.Mappings`, `Extension.Mappings`. Removed `specModulePath`/`mappingsModulePath` from `ExtensionPoint_Builder.Config`. Removed `BundledSliceConfig` type. Removed `resolveModule`/package path variables from AWS plugin files.
8. [x] `EventMapperEntryPoint.res` — DynamoDB Stream handler, event-to-command mapping (Micro mode only). Added `moduleUrl` to `EventMapper.Mappings`. Updated `AggregateRuntime_Builder_Micro` to use `makeFromCodeAsset`. Added `moduleUrl` to `NoEventMappings.Make`.
9. [x] `TaskBucketEntryPoint.res` — S3 event handler. Builder updated to use `makeFromCodeAsset`. `callbackModulePaths` remain in Config (Task callbacks aren't first-class modules with `moduleUrl`).
10. [x] `CounterEntryPoint.res` — reference counting with DynamoDB. Complex handler with references/counts stream partitioning, sury schema, Counter_Callback + MakeCounterHandler wiring.
11. [x] `DcbCommandTopicEntryPoint.res` — composite SQS handler routing between StateChangeSlice handlers. Added `moduleUrl` to `StateChangeSlice.Spec` and `InboundTranslationSlice.Spec`. Auto-registers spec paths via `StateChangeSlice_Builder.Make`. Removed manual `stateChangeSliceSpecPaths` from `Main.res` files.
12. [x] `PluginExtensionPointEntryPoint.res` — platform-internal extension point. No user modules (all framework imports). Reconstructs scheduler, queryEngine (with real DynamoDB scan), resourceNaming, and PluginExtensionPoint_Plugin mapping.
13. [x] `AdminEventCollectorEntryPoint.res` — most complex, platform admin handler. Reconstructs SNS publish, AppSync schema stitching (dynamic `import()` for AWS SDK), scheduler, queryEngine, resourceNaming, and PluginExtensionPoint_Plugin mapping with `updateApiSchema`.

**All 13 entry points migrated.** Each follows the pattern: compiled `*EntryPoint.res` in the Layer, `HANDLER_CONFIG` JSON env var, `makeFromCodeAsset` with static re-export + user packages in code asset.

**`moduleUrl` added to module types:** `Aggregate.Spec`, `Behavior.T`, `SideEffect.T`, `StateViewSlice.Spec`, `ReadModel.Spec`, `Projection.Mappings`, `AutomationSlice.Spec`, `OutboundTranslationSlice.Spec`, `ExtensionMapping.Spec`, `ExtensionMapping.Mappings`, `Extension.Mappings`, `EventMapper.Mappings`, `StateChangeSlice.Spec`, `InboundTranslationSlice.Spec`

**Eliminated:** `BundledSliceConfig` type, manual `resolveModule` calls in plugin files, manual `stateChangeSliceSpecPaths` in `Main.res`, `Config` module types from `ReadModel_Builder_Single`, `ReadModel_Builder_NoResolver`, `SideEffectHandler_Single`, `StateViewSlice_Builder_Bundled`, `AutomationSlice_Builder_Bundled`, `OutboundTranslationSlice_Builder_Bundled`.

### Step 5 Verification ✅

- [x] All 13 `*EntryPoint.res` files compile without Pulumi imports
- [x] Build with zero warnings (only pre-existing deprecation): `npm run build`
- [x] All 810 tests pass across 96 test suites: `npm test`
- [x] Deploy platform-aws stack (5 Lambdas updated with layers)
- [x] Deploy catalog-aws stack (17 new code assets created, 5 Lambdas updated with layers)
- [x] Deploy ordering-aws stack (12 new code assets created, 5 Lambdas updated with layers)
- [x] Invoke aggregate command (Category via SQS) — handler routing, dynamic import, functor wiring all confirmed working
- [x] Cold start: ~1054ms init + 60ms handler — comparable to previous esbuild approach
- [ ] Verify AppSync CommandGenerator route works
- **Note**: `REVENTLESS_LAYER_ARN` must be set when deploying locally (CI sets it automatically). The `-aws` example packages require separate `rescript clean && rescript build` from their directories (not included in root `npm run build`).
- **Note**: Lambda Layer must be rebuilt to include new `*EntryPoint.res.mjs` files before non-Aggregate entry points work at runtime. Layer version 35 includes only `AggregateEntryPoint` and `HeartbeatEntryPoint` from previous sessions.

## Step 6: Clean up

### Completed:
- [x] Delete `ProjectionRuntime_Builder_Single.res` — no remaining callers (all Single-mode builders now inline their own `finish()`)
- [x] Remove `resolveModule` external from `Util_Bundle.res` — no remaining callers

### Cleanup completed:

- [x] Delete `Util_EntryPoint.res`, `Util_EntryPoint.mjs`, `Util_EntryPoint.res.mjs` (~1,070 lines)
- [x] Delete all 14 `*HandlerFactory.mjs` files (~1,500 lines)
- [x] Remove `bundleHandler`/`bundleEntryPoint` from `Util_Bundle.res` and `Util_Bundle.mjs`
- [x] Remove `makeBundled` and `makeBundledFromEntryPoint` from `RuntimeEnvironment_Lambda.res`
- [x] Remove `BundledEnvironment` module type, `handlerRef` type, `bundledEnvironmentMaker` type from `Runtime.res`
- [x] Remove `esbuild` from `reventless-aws` dependencies
- [x] Remove `resolveModule` and esbuild-related code (`buildAndArchive`, `stableTmpDir`, `findProjectRoot`) from `Util_Bundle.mjs`

### Remaining:
- [x] Update the analysis doc to reflect completion
- [x] `HandlerFactoryHelpers.mjs` → `HandlerFactoryHelpers.res` — converted to ReScript. `makeTableRef` and `makeQueueRef` are pure ReScript records. `patchSpecId` uses `%raw` with `IdString` imported via `%%raw`. `scanByTableName` uses `%raw` with lazy DynamoDB client (DynamoDB SDK imported via `%%raw`). All 13 EntryPoint files updated to import from `.res.mjs`. Old `.mjs` file deleted.
- [ ] Update Lambda Layer builder to include new `*EntryPoint.res.mjs` and `HandlerFactoryHelpers.res.mjs` files — blocked on publishing the updated `@reventlessdev/reventless-aws` package to npm registry, since the layer builder downloads from the registry. Until then, deployed Lambdas that use non-Aggregate/non-Heartbeat entry points will fail (Layer doesn't include them yet).
- [ ] Deploy full online-shop-hybrid stacks with rebuilt Layer — blocked on the above.
- [ ] Move this plan to `docs/plans/done/` — blocked on successful deployment verification.

## Step 7: Migrate alternative deployment modes

The `Single` deployment mode (one shared Lambda per component type) is fully migrated. Three alternative modes still use the old `Util_EntryPoint` code generation + esbuild pipeline. Each creates **one Lambda per component instance** rather than grouping into a shared Lambda.

### 7a. `AggregateRuntime_Builder_PerAggregate` ✅

One Lambda per aggregate (CommandTopic + EventCollector combined). Used by `Aggregate_Builder_PerAggregate`.

Replaced `finish()` to use `makeFromCodeAsset` with single-handler `HANDLER_CONFIG` JSON env var + static re-export to `AggregateEntryPoint.res.mjs`. User packages collected via `extractPackageName`/`resolvePackageRoot`/`createFilteredPackageArchive`.

### 7b. `AggregateRuntime_Builder_Micro` ✅

Separate Lambdas per aggregate for: CommandTopic, CommandGenerator, EventMapper. The most granular deployment mode.

Replaced CmdTopic and CmdGen Lambda creation in `finish()` to use `makeFromCodeAsset` with `HANDLER_CONFIG` + static re-export to `AggregateEntryPoint.res.mjs`. EventMapper was already migrated in Step 5 (#8). User packages shared between CmdTopic and CmdGen Lambdas.

### 7c. `EventCollectorRuntime_Builder_PerEventCollector` ✅

One Lambda per EventCollector (ReadModel, SideEffectHandler, ForeignReadModel). Used by `ReadModel_Builder_PerReadModel`, `SideEffectHandler_PerSideEffectHandler`, `ForeignReadModel_Builder`, `Task_Builder_PerBucket`.

Replaced `forEventCollector` to use `makeFromCodeAsset` with single-handler `HANDLER_CONFIG` JSON env var + static re-export to `ReadModelEntryPoint.res.mjs`. Same pattern as the Single builder but per-component.

### 7d. Remaining esbuild users (non-deployment-mode) ✅

Two standalone components used `Util_Bundle.bundleEntryPoint` directly:
- `Util_DeadLetterQueue.res` — replaced with `Pulumi.Archive.assetArchive` + `Pulumi.Asset.stringAsset` (trivial one-liner handler, no esbuild needed)
- `ClonerRunner_Fargate.res` — same replacement (inline JS with `@aws-sdk/client-ecs` import, resolved from Lambda runtime)

### After Step 7:

All alternative modes migrated. Cleanup completed in Step 6 — see above.

## Risk Assessment

- **Dynamic `import()` cold start**: ~10-50ms added to cold start. **MEASURED**: ~1003ms init (includes dynamic import), warm 268ms. Comparable to previous approach.
- **Pulumi transitive imports**: ~~The biggest risk.~~ **RESOLVED** — all runtime functors are already Pulumi-free. No module splitting needed.
- **ESM import resolution from Layer**: `import()` in entry points at `/opt/nodejs/node_modules/` resolves relative to the Layer, not `/var/task/`. **RESOLVED**: `dynamicImport` uses absolute path `/var/task/node_modules/` prefix for user modules.
- **User module packaging**: `createFilteredPackageArchive` includes only `*.res.mjs` + `package.json`, excluding `lib/`, `tests/`, `__mocks__/`, `*.res`, `CHANGELOG`, etc.
- **`patchSpecId` workaround**: The `module Id = Id.String` ESM export issue persists. The compiled entry point handles this the same way the JS factories do — with a runtime patch.
- **Layer rebuild required**: New `*EntryPoint.res.mjs` files must be included in the Lambda Layer. The layer builder downloads from npm registry, so a local workaround (manual copy) is needed until the package is published.

## Dependencies

- Step 1 is independent (done)
- Step 2 is independent (decision, no code)
- Step 2b depends on Step 2 (moduleUrl approach)
- Step 3 is skipped (prerequisite analysis showed no splits needed)
- Step 4 depends on Step 2 only
- Step 5 depends on Step 4 (pattern validation)
- Step 6 depends on Step 5 (all migrations complete)

## What gets deleted

| File | Lines | Replaced by |
|------|-------|-------------|
| `Util_EntryPoint.mjs` | 838 | Compiled `*EntryPoint.res` modules |
| `Util_EntryPoint.res` (externals) | 232 | No longer needed |
| `AggregateHandlerFactory.mjs` | 94 | `AggregateEntryPoint.res` |
| `ReadModelHandlerFactory.mjs` | 93 | `ReadModelEntryPoint.res` |
| `ExtensionPointHandlerFactory.mjs` | 93 | `ExtensionPointEntryPoint.res` |
| `EventMapperHandlerFactory.mjs` | 96 | `EventMapperEntryPoint.res` |
| `AutomationSliceHandlerFactory.mjs` | 84 | `AutomationSliceEntryPoint.res` |
| `StateViewSliceHandlerFactory.mjs` | 69 | `StateViewSliceEntryPoint.res` |
| `CommandGeneratorHandlerFactory.mjs` | 43 | `CommandGeneratorEntryPoint.res` |
| `SideEffectHandlerFactory.mjs` | 47 | `SideEffectEntryPoint.res` |
| `HeartbeatHandlerFactory.mjs` | 51 | `HeartbeatEntryPoint.res` |
| `TaskHandlerFactory.mjs` | 88 | `TaskBucketEntryPoint.res` |
| `CounterHandlerFactory.mjs` | 141 | `CounterEntryPoint.res` |
| `DcbCommandTopicHandlerFactory.mjs` | 157 | `DcbCommandTopicEntryPoint.res` |
| `PluginExtensionPointHandlerFactory.mjs` | 142 | `PluginExtensionPointEntryPoint.res` |
| `AdminEventCollectorHandlerFactory.mjs` | 216 | `AdminEventCollectorEntryPoint.res` |
| `HandlerFactoryHelpers.mjs` | 150 | `HandlerFactoryHelpers.res` (ReScript with `%raw` for `patchSpecId` + `scanByTableName`) |
| `Util_Bundle.mjs` | 155 | Removed (esbuild no longer needed) |
| 3 `index.mjs` (applications) | ~30 | Moved to `Main.res` (done) |
| **Total deleted** | **~2,570** | |
