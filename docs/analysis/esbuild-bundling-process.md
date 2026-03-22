# Analysis: esbuild Bundling Process in reventless-aws

> **Status: Migration complete.** Alternative D was implemented — see [migration plan](../plans/migrate-bundling-js-to-rescript.md). All 13 component types now use compiled `*EntryPoint.res` modules in the Lambda Layer with `HANDLER_CONFIG` JSON env vars. esbuild removed from dependencies. ~2,565 lines of hand-written JavaScript deleted. Only `HandlerFactoryHelpers.mjs` (150 lines) remains, used by the new entry points for `patchSpecId`, `makeTableRef`, `makeQueueRef`, and `scanByTableName`.

## What is esbuild?

[esbuild](https://esbuild.github.io/) is an extremely fast JavaScript/TypeScript bundler written in Go. It takes one or more entry point files, follows all `import`/`require` statements, and produces a single output file containing all reachable code. Key features used by this project:

- **Bundling**: Resolves and inlines all imports into a single file
- **Externals**: Packages listed as `external` are left as `import` statements in the output — not bundled. The runtime environment must provide them (e.g., via a Lambda Layer or the Node.js runtime itself)
- **Format**: Outputs ESM (`import`/`export`) or CommonJS (`require`/`module.exports`)
- **Platform targeting**: Optimizes for a specific Node.js version (e.g., `node22`)
- **Synchronous API**: `esbuild.buildSync()` runs bundling synchronously — important because Pulumi's deploy-time code is synchronous

### How esbuild is used in Reventless

esbuild is used at **Pulumi deploy time** (not at Lambda runtime) to create Lambda deployment packages. The pipeline:

```
Deploy time (pulumi up):
  1. Generate a small JS entry point string (imports + wiring)
  2. Write it to a temp file
  3. esbuild.buildSync() bundles it into a single index.mjs
  4. The bundle is wrapped in a Pulumi AssetArchive
  5. Pulumi uploads it as the Lambda's code asset
```

Crucially, **framework code and runtime dependencies are externalized** — they live in the Lambda Layer (`/opt/nodejs/node_modules/`). The bundle contains only the entry point glue code plus the **user's business logic** (Spec, Behavior, Mappings modules).

Externalized packages (not bundled, provided by Layer or Lambda runtime):
- `@aws-sdk/*`, `@smithy/*` — provided by Lambda runtime
- `@reventlessdev/*`, `@rescript/*` — provided by Lambda Layer
- `effect`, `effect/*`, `sury`, `sury/*` — provided by Lambda Layer
- `@standard-schema/*`, `uuid`, `hash-object` — provided by Lambda Layer

**Bundled into the Lambda code asset:**
- The entry point wrapper (imports, handler wiring, env var reading)
- User's Spec, Behavior, and Mappings modules — these are resolved to **absolute file paths** by `resolveModule()` at deploy time (e.g., `/abs/path/to/Category.res.mjs`). Since absolute paths don't match the `@reventlessdev/*` externals pattern, esbuild inlines them into the bundle.

This means the framework code is shared across all Lambdas via the Layer, while each Lambda's code asset contains only its specific business logic and the wiring glue.

### Why esbuild was chosen

esbuild was introduced to replace Pulumi's `CallbackFunction` mechanism (see `docs/plans/done/bundled-lambda-handlers.md`). `CallbackFunction` serialized JavaScript closures at deploy time, which failed with Effect-TS runtime objects. esbuild provides a file-based alternative: instead of serializing closures, it bundles a module file into a self-contained deployment package.

---

## Alternatives to esbuild

### Alternative A: Direct file copy (no bundler)

Since nearly everything is externalized, the esbuild bundle is essentially just the entry point file itself with import paths resolved. Could we skip esbuild entirely and just copy/create the entry point file directly?

**How it would work:**
1. Create the entry point code (same as today)
2. Instead of writing to temp file → esbuild → read output, just put the code directly into a `Pulumi.asset.StringAsset`
3. Lambda loads the entry point, which imports framework code from the Layer and user modules directly

**Why this is NOT straightforward:** esbuild does more than just wrap the entry point. It resolves and **inlines the user's business logic** (Spec, Behavior, Mappings modules) into the bundle. These modules are imported by absolute file paths (resolved via `resolveModule` at deploy time), so they don't match the externals pattern and get bundled. Without esbuild, the Lambda code would need another mechanism to include the user modules — either by adding them to the Layer, or by constructing a multi-file code asset.

**What esbuild provides:**
- **User module bundling**: Inlines Spec, Behavior, and Mappings modules (absolute paths) into the code asset. This is the primary value — without it, these files would need to be included separately.
- **CJS compatibility banner**: Injects `import { createRequire } from 'module'; const require = createRequire(import.meta.url);`.
- **Content hashing**: The bundled output is hashed for Pulumi change detection.
- **Import path resolution**: Resolves relative imports within the bundled modules.

**Verdict**: Direct file copy is **not viable as-is** because the user's business logic modules must be included in the Lambda code asset. However, this could be solved by constructing a multi-file `AssetArchive` that includes the entry point plus the user module files — essentially doing manually what esbuild does automatically. This is more complex than the current approach and loses the single-file simplicity.

### Alternative B: Pre-compiled entry points in the Layer

Instead of generating entry point code at deploy time, include **pre-compiled ReScript entry point modules** in the Lambda Layer. Each component type (Aggregate, ReadModel, etc.) gets a generic entry point that reads its configuration from an environment variable.

**How it would work:**
1. Write one `AggregateEntryPoint.res` per component type — compiled ReScript, included in Layer
2. At deploy time, set `HANDLER_CONFIG` env var with JSON: `{"specModule": "...", "behaviorModule": "...", "eventLogTable": "...", "queueUrl": "..."}`
3. Lambda handler: `handler: "AggregateEntryPoint.handler"` (points to Layer code)
4. At cold start: parse config, `import()` user modules, wire up functor chain

**Advantages:**
- **No code generation at all** — eliminates `Util_EntryPoint` entirely
- **No esbuild** — entry point is pre-compiled in the Layer
- **No temp files** — deploy time just sets env vars
- **Compiler-verified** — the entry point imports framework functors via normal ReScript imports; signature changes cause build errors
- **Faster deploys** — no esbuild invocation per Lambda function

**Challenges:**
- **Dynamic `import()`**: User modules (Spec, Behavior) must be loaded dynamically at cold start since their paths come from config. Adds ~10-50ms to cold start (acceptable given current ~500ms cold starts).
- **User modules must be in the Layer**: Currently, user business logic (Spec, Behavior, Mappings) is bundled into the Lambda code asset by esbuild. With pre-compiled entry points in the Layer, user modules must also be resolvable at runtime — either included in the Layer, or added to the Lambda code as a multi-file asset. Including them in the Layer is simpler (they're npm packages, already eligible for Layer inclusion) but means the Layer must be rebuilt when business logic changes. Alternatively, the user modules' npm packages could be added as additional Lambda Layers.
- **Pulumi transitive imports**: The entry point modules call framework functors that currently import `@pulumi/pulumi` transitively. These modules need to be split into deploy-time and runtime-only variants. This is the same refactoring needed regardless of approach.
- **Lambda handler path**: Lambda's `handler` field must point to a module in the Layer. The Layer's `node_modules/@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.res.mjs` can be referenced as `@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.handler` — but Lambda requires the handler to be in the function's code package or a Layer, using `index.handler` format.

**Lambda handler resolution caveat**: AWS Lambda resolves the handler path relative to the function code root or Layer paths. For Layer code, the module must be accessible via Node.js module resolution from `/opt/nodejs/node_modules/`. Since `@reventlessdev/reventless-aws` is already in the Layer, the entry point module would be found at `/opt/nodejs/node_modules/@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.res.mjs`. The Lambda handler could be set to `@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.handler` — but this depends on Lambda's ESM handler resolution supporting deep package paths.

Alternatively, the function code asset could contain a minimal one-line re-export: `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.res.mjs"`. This is essentially "Alternative A" but with a static, non-generated import pointing to a compiled module in the Layer.

**Verdict**: This is the **ideal long-term architecture**. It eliminates code generation, esbuild, and most hand-written JavaScript. The main investment is splitting framework modules to avoid Pulumi transitive imports — work that pays off regardless of which approach is chosen.

### Alternative C: Tree-shaking the compiled ReScript output

Instead of using a Layer for framework code + a bundled entry point, bundle the **entire handler** (framework + user code) into a single self-contained file using esbuild with tree-shaking enabled.

**How it would work:**
1. Write a real ReScript entry point module (as in Alternative B)
2. At deploy time, esbuild bundles it with `bundle: true` and NO externals — everything is inlined
3. esbuild's tree-shaking eliminates unused code paths
4. The resulting bundle is the complete Lambda — no Layer needed

**Advantages:**
- **No Lambda Layer** — eliminates Layer management, ARN tracking, CI/CD for Layer publishing
- **Self-contained Lambdas** — each function contains exactly the code it needs
- **Potentially smaller cold start** — only used code is loaded

**Challenges:**
- **Bundle size**: Without externalization, each bundle includes all transitive dependencies (Effect, sury, @rescript/runtime, AWS SDK bindings). Even with tree-shaking, this could be 5-20MB per Lambda.
- **Deploy time**: Bundling everything takes longer than bundling a tiny wrapper (~2-5s vs ~0.5s per Lambda).
- **Duplicate code across Lambdas**: Each Lambda bundles its own copy of shared code. With 10+ Lambdas per plugin, total deployment size grows significantly.
- **ReScript compiled output is not tree-shakeable**: ReScript generates ESM output with module-level side effects (e.g., `let Make = ...` at module scope). esbuild cannot eliminate unused exports from these modules because it cannot prove the module initialization is side-effect-free. The `/* @__PURE__ */` annotation that enables tree-shaking is not emitted by the ReScript compiler.

**Verdict**: **Not recommended** for this project. The Lambda Layer approach is more efficient (shared code, smaller individual functions, faster deploys). Tree-shaking is ineffective on ReScript output, so bundles would be large. The Layer already exists and works well.

### Alternative D: Hybrid — compiled entry points with minimal code asset

Combine the best of A and B:
1. **Handler factories** are real compiled ReScript modules in the Layer (as in Alternative B) — compiler-verified functor chains
2. **Entry point** is a minimal, non-generated code asset — a one-line re-export from the Layer module
3. **Configuration** is passed via environment variables (as in Alternative B)
4. **User business logic** (Spec, Behavior, Mappings) is included in the Lambda code asset alongside the entry point, OR provided via an additional Layer

The function code asset contains:
```javascript
// index.mjs — static, same for all Aggregates
export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.res.mjs";
```

Plus the user's compiled Spec/Behavior/Mappings modules, packaged as additional files in the `AssetArchive` (or, if the user's plugin is an npm package installed in the Layer, they're already available).

Per-Lambda differences are in env vars only. No code generation.

**How user modules reach the Lambda:**
- **Option 1: Multi-file AssetArchive** — at deploy time, `resolveModule` finds the user's Spec/Behavior files on disk. These files (plus their local imports) are added to the Lambda's `AssetArchive` alongside `index.mjs`. This replaces esbuild's bundling of user modules.
- **Option 2: User package in Layer** — if the user's plugin is published as an npm package (e.g., `@reventlessdev/online-shop-hybrid-catalog`), it can be included in the Lambda Layer by the layer builder. The entry point resolves it via standard Node.js module resolution from `/opt/nodejs/node_modules/`. This is simpler but means the Layer must be rebuilt when user code changes.
- **Option 3: Additional Lambda Layer** — the user's plugin packages are built into a separate Lambda Layer. This separates framework Layer (stable) from user Layer (changes with business logic). Each Lambda attaches both layers. This avoids rebuilding the framework Layer for user code changes.

**No esbuild needed** — the one-line re-export can be created as a `Pulumi.asset.StringAsset` directly. User modules are included via `AssetArchive` (file copy) or Layer (package install).

**Verdict**: This is the **most pragmatic approach**. It gets the compiler-verification benefits of Alternative B without the Lambda handler path complexity. The one-line re-export is trivially simple and never changes. The user module packaging has multiple viable options depending on the deployment model.

### Recommendation

**Alternative D (Hybrid)** is recommended for implementation:

| Aspect | Current | Alternative D |
|--------|---------|--------------|
| Entry point code | 838 lines of generated JS strings | One static re-export line per component type |
| User business logic | Bundled by esbuild (absolute path resolution) | Multi-file AssetArchive, additional Layer, or user package in framework Layer |
| esbuild | Required per Lambda, ~0.5s each | Not needed |
| Code generation | `Util_EntryPoint` generates JS strings at deploy time | None — static re-export + env var config |
| Factory wiring | Hand-written JS calling functors by name | Compiled ReScript, compiler-checked |
| Framework change | Breaks silently at runtime | Compiler error at build time |
| Deploy-time work | Generate → write temp → esbuild → read → hash → archive | Create StringAsset with re-export + copy user files |

The main prerequisite is splitting framework modules to avoid Pulumi transitive imports in the runtime entry points. This refactoring is needed regardless of approach and is separately analyzed in the "Pulumi Import Problem" section below.

---

## Current Implementation Details

There are **two distinct bundling systems** in this monorepo:

1. **Lambda Layer Builder** (`reventless-layer-builder/`) — already written in ReScript, not a concern
2. **Lambda Handler Bundling** (`reventless-aws/src/`) — the problematic part with hand-written JavaScript

The handler bundling is where the fragile, hard-to-maintain JavaScript lives. This section covers how it works in detail.

---

## How the Current Handler Bundling Works

### The Pipeline (deploy-time, inside Pulumi)

```
ReScript Runtime Builders (*.res)
  → call Util_EntryPoint.mjs to generate JS code strings
  → pass those strings to Util_Bundle.mjs which:
    1. Writes code to a temp file
    2. Runs esbuild.buildSync() to bundle it
    3. Returns a Pulumi AssetArchive + content hash
  → Pulumi deploys the bundle as a Lambda function
```

### The Three Layers of JavaScript

| Layer | Files | Lines | Purpose |
|-------|-------|-------|---------|
| **1. esbuild runner** | `Util_Bundle.mjs` | 155 | Temp file creation, `esbuild.buildSync()`, hashing, archive creation |
| **2. Entry point generators** | `Util_EntryPoint.mjs` | 838 | Generate JS code strings with template literals for each component type (13 generator functions) |
| **3. Handler factories** | `*HandlerFactory.mjs` (15 files) | ~1,400 | Reconstruct the full handler chain at runtime — rewiring functors, patching module aliases, creating shims |

**Total hand-written JS: ~2,400 lines across 17 files**

### Why These Are JavaScript (claimed reasons)

The comment in `Util_EntryPoint.mjs` says:
> "The generated code contains JS template literals and dynamic imports — syntax that is impractical to express in ReScript string templates."

This is partially true but mostly an excuse. The real challenges are:

1. **String code generation**: The entry point generators produce *JavaScript source code as strings* — string interpolation with embedded `import` statements, `process.env.XXX` references, and template literal escapes
2. **Module alias workarounds**: `patchSpecId()` compensates for `module Id = Id.String` not producing a runtime export in ESM
3. **Functor chain reconstruction**: The handler factories manually call `Make(Spec)(Behavior)(Ops)` — the same functor chains that ReScript constructs at compile time, but done dynamically in JS
4. **Pulumi import avoidance**: Several factories inline functionality (e.g., `scanByTableName` in `HandlerFactoryHelpers.mjs`) to avoid importing modules that transitively pull in `@pulumi/pulumi`

---

## File-by-File Breakdown

### Layer 1: `Util_Bundle.mjs` (esbuild runner)

**Location**: `reventless-aws/src/util/Util_Bundle.mjs`

**What it does:**
- `findProjectRoot()` — walks up from `import.meta.url` until it finds `node_modules`
- `resolveModule(specifier)` — resolves a module specifier to an absolute file path via `createRequire`
- `stableTmpDir(content)` — creates a content-hash-based temp dir so esbuild output is deterministic
- `buildAndArchive(wrapperPath)` — the core function:
  1. Runs `esbuild.buildSync()` with ESM format, node22 target
  2. Externalizes `@aws-sdk/*`, `@smithy/*`, `effect`, `sury`, `@reventlessdev/*`, `@rescript/*`, `uuid`, `hash-object`
  3. Reads the bundled output as a string
  4. Creates a SHA-256 hash for Pulumi change detection
  5. Returns `{ code: Pulumi.asset.AssetArchive, sourceCodeHash }`
- `bundleHandler(entryPoint, exportName)` — wraps a single export as `handler`
- `bundleEntryPoint(entryPointCode)` — bundles arbitrary JS code string

**ReScript companion**: `Util_Bundle.res` exists but only contains `@module` external bindings to the `.mjs` file.

### Layer 2: `Util_EntryPoint.mjs` (code string generators)

**Location**: `reventless-aws/src/util/Util_EntryPoint.mjs`

**13 generator functions**, each producing a complete Lambda entry point as a JavaScript string:

| Function | Component Type |
|----------|---------------|
| `generateAggregateEntryPoint` | Aggregate (SQS command handler + AppSync CommandGenerator) |
| `generateReadModelEntryPoint` | ReadModel (EventCollector → projection) |
| `generateStateViewSliceEntryPoint` | StateViewSlice |
| `generateAutomationSliceEntryPoint` | AutomationSlice |
| `generateOutboundTranslationSliceEntryPoint` | OutboundTranslationSlice |
| `generateExtensionPointEntryPoint` | ExtensionPoint |
| `generatePluginExtensionPointEntryPoint` | Plugin ExtensionPoint |
| `generateAdminEventCollectorEntryPoint` | Admin EventCollector |
| `generateCommandGeneratorEntryPoint` | CommandGenerator |
| `generateEventMapperEntryPoint` | EventMapper |
| `generateSideEffectEntryPoint` | SideEffectHandler |
| `generateTaskBucketEntryPoint` | Task bucket handler |
| `generateCounterEntryPoint` | Counter |
| `generateDcbCommandTopicEntryPoint` | DCB CommandTopic |
| `generateHeartbeatEntryPoint` | Heartbeat |

**Common pattern in every generator:**
1. Build `import` lines from config paths
2. Generate a `runEffect` helper that provides `RequestContext`
3. Generate handler initialization from factory functions
4. Generate a `groupBySource` helper (for multi-source handlers)
5. Generate the `export const handler` function

**ReScript companion**: `Util_EntryPoint.res` exists with all config types defined, but only `@module` external bindings — no implementations.

### Layer 3: Handler Factories (runtime functor wiring)

**Location**: `reventless-aws/src/adapter/Runtime/*.mjs` (hand-written, NOT `*.res.mjs`)

Each factory reconstructs the framework's functor chain that normally runs at deploy-time, but using environment variables and static imports instead of Pulumi Output values.

**Example — `AggregateHandlerFactory.mjs`:**
```javascript
// Reconstructs: CommandTopic_Callback.Make(Spec)({commandsHandler:
//   Aggregate_Callback.Make(Spec)(Behavior)({eventLog:
//     EventLog_Operations.Make(Spec)(storage)}).handleCommands})
const eventLogOps = EventLogOperationsMake(patchedSpec)({...});
const aggregateCallback = AggregateCallbackMake(patchedSpec)(behaviorModule)({...});
const commandTopicCallback = CommandTopicCallbackMake(patchedSpec)({...});
return handleQueueEvent(resolvedQueue, commandTopicCallback.handleJsonCommands);
```

**`HandlerFactoryHelpers.mjs`:**
- `patchSpecId(specModule)` — patches `module Id = Id.String` ESM export issue
- `makeTableRef(name)` / `makeQueueRef(url)` — creates minimal infrastructure stubs
- `scanByTableName(tableName, filterConfigs, limit)` — full DynamoDB scan implementation (reimplemented to avoid importing `QueryEngine_DynamoDb` which pulls in Pulumi)

**`AdminEventCollectorHandlerFactory.mjs`** — the most complex factory (216 lines):
- Reconstructs the full Admin EventCollector handler chain
- Inlines AppSync schema stitching logic
- Reimplements `@aws_auth` injection to avoid importing `AppSync_Adapter`
- Creates mock scheduler, query engine, and resource naming objects

---

## Why This Is Fragile

1. **No type checking**: The JS factories call ReScript functor chains by shape — if `Aggregate_Callback.Make` changes its parameter structure, these files silently break at runtime
2. **Duplicated logic**: `scanByTableName` reimplements `QueryEngine_DynamoDb` scan logic; `injectAwsAuthAll` reimplements `AppSync_Adapter` logic — both drift independently
3. **Invisible coupling**: The generated entry point code depends on exact export names from `*HandlerFactory.mjs` files — no compiler checks
4. **Module path brittleness**: Entry point generators hardcode paths like `@reventlessdev/reventless-core/src/components/Aggregate/Aggregate_Callback.res.mjs` — renaming or moving files breaks silently

---

## What Could Be Moved to ReScript

### Layer 1: `Util_Bundle.mjs` — Fully replaceable

All logic can be ReScript with bindings for `esbuild`, `fs`, `os`, `crypto`, `path`:

```rescript
module Esbuild = {
  type buildOptions = {
    entryPoints: array<string>,
    bundle: bool,
    outfile: string,
    format: string,
    platform: string,
    target: string,
    external: array<string>,
    absWorkingDir: string,
    nodePaths: array<string>,
    banner: dict<string>,
    minify: bool,
    sourcemap: bool,
  }
  type buildResult = {errors: array<JSON.t>}
  @module("esbuild") external buildSync: buildOptions => buildResult = "buildSync"
}

// findProjectRoot, stableTmpDir, buildAndArchive — all plain ReScript
// with NodeFs, NodePath, Crypto bindings
```

**Residual JS**: None.

### Layer 2: `Util_EntryPoint.mjs` — Fully replaceable

The claim that "JS template literals are impractical in ReScript" is incorrect. ReScript has template literal strings (`` `...${expr}...` ``). The generated code contains nested JS template literals, but those are just escaped strings in the output.

All 13 generator functions become ReScript functions returning strings. The config types already exist in `Util_EntryPoint.res`:

```rescript
let generateAggregateEntryPoint = (config: aggregateEntryPointConfig): string => {
  let importLines = [
    `import { createCommandTopicHandler } from ${JSON.stringify(config.factoryModule)};`,
    `import * as Effect from "effect/Effect";`,
    `import * as RequestContext from ${JSON.stringify(config.requestContextModule)};`,
  ]

  let handlerImports = config.handlers->Array.mapWithIndex((h, i) => [
    `import * as Spec_${Int.toString(i)} from ${JSON.stringify(h.specModulePath)};`,
    `import * as Behavior_${Int.toString(i)} from ${JSON.stringify(h.behaviorModulePath)};`,
  ])->Array.flat

  // ... build the full handler string with string concatenation
}
```

Shared helper strings (like `runEffect`, `groupBySource`, `extractCorrelationId`) can be extracted as ReScript string constants, eliminating the massive duplication across all 13 generators.

**Residual JS**: None.

### Layer 3: Handler Factories — Mostly replaceable

The factories do three things:

1. **Call ReScript functor chains** — `Make(Spec)(Behavior)(Ops)` — this works fine from ReScript; it's literally what the framework does at deploy time
2. **Construct shim objects** — `{ name: tableName }`, `{ id: url, name: url, arn: "" }` — trivial in ReScript
3. **Avoid Pulumi imports** — this is the real constraint

**The Pulumi Import Problem:**

The factories exist as separate `.mjs` files because they call framework functions (like `EventLog_Operations.Make`) **without** importing `@pulumi/pulumi`. Many framework modules transitively import Pulumi because they use `Pulumi.Output.t` in their type signatures.

**Solutions in ReScript:**
- **Separate compilation units** with `.resi` interface files that don't expose Pulumi types
- **Runtime-only modules** (the `*_Runtime.res.mjs` pattern already exists in the codebase)
- **Extracting runtime-only logic** from modules that currently mix deploy-time and runtime code

For `HandlerFactoryHelpers.mjs`:
- `patchSpecId` — should be fixed at the source (ensure `module Id = Id.String` produces an ESM export), or be a 3-line ReScript function
- `makeTableRef` / `makeQueueRef` — trivial ReScript record constructors
- `scanByTableName` — can be a ReScript module using `rescript-aws-sdk` DynamoDB bindings (already in the repo)

For `AdminEventCollectorHandlerFactory.mjs`:
- The most complex factory, but still doable as ReScript
- The inline `injectAwsAuthAll` and DynamoDB scan should call the real framework functions, not reimplementations
- Requires ensuring those framework functions don't transitively import Pulumi

**Residual JS**: Potentially `patchSpecId` (3 lines) if the ESM module alias issue isn't fixed upstream. Otherwise none.

---

## Porting Summary (ReScript string approach)

This section summarizes what's possible if taking the simpler approach of porting the JS files to ReScript while keeping the code-string-generation architecture. See "The Deeper Problem" section below for why this is not the recommended long-term approach.

| Component | Current | Lines | Can be ReScript? | Residual JS |
|-----------|---------|-------|-----------------|-------------|
| `Util_Bundle.mjs` | esbuild runner | 155 | Yes, with bindings | None |
| `Util_EntryPoint.mjs` | code string generators | 838 | Yes, string concat | None |
| 15 `*HandlerFactory.mjs` | runtime functor wiring | ~1,400 | Yes, with runtime adapter pattern | ~3 lines (`patchSpecId`) |
| `HandlerFactoryHelpers.mjs` | DynamoDB scan + helpers | 150 | Yes, with AWS SDK bindings | None |
| **Total** | | **~2,400** | | **~0-3 lines** |

**~2,400 lines of JS → ~0-3 lines of JS**, with everything else as type-safe ReScript that compiles and is checked against the actual framework types. However, the generated code strings still contain hardcoded module paths and export names that break silently when the framework changes.

---

## Application-Level `index.mjs` Files

### Current State

Each Pulumi application stack has a hand-written `index.mjs` file as its entry point (configured via `Pulumi.yaml: main: src/index.mjs`):

**`platform-aws/src/index.mjs`** — trivial re-export:
```javascript
export { default } from "./Main.res.mjs";
```

**`catalog-aws/src/index.mjs`** and **`ordering-aws/src/index.mjs`** — registration + re-export:
```javascript
import { registerDcbConfig } from "@reventlessdev/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res.mjs";
import { resolveModule } from "@reventlessdev/reventless-aws/src/util/Util_Bundle.res.mjs";

const pkg = "@reventlessdev/online-shop-hybrid-catalog/src";
registerDcbConfig("Catalog", undefined, [
  resolveModule(pkg + "/Product/StateChangeSlice/AddProduct.res.mjs"),
  resolveModule(pkg + "/Product/StateChangeSlice/ChangeProductName.res.mjs"),
  // ...more slice paths
], undefined);

export { default } from "./Main.res.mjs";
```

### Why They Exist

These files serve two purposes:

1. **Pulumi entry point**: Pulumi's Node.js runtime requires a `main` file that exports the stack outputs. The `export { default } from "./Main.res.mjs"` line re-exports `Pulumi.Pulumi.getOutputs()` from the compiled ReScript.

2. **DCB registration side-effect**: For plugins using DCB (Dynamic Consistency Boundary), `registerDcbConfig` must be called with **resolved absolute file paths** to StateChangeSlice spec modules *before* `Main.res.mjs` runs. The `resolveModule()` function uses `createRequire(import.meta.url)` under the hood to resolve npm package specifiers to absolute paths on disk.

### Can They Be Eliminated?

**Yes, entirely.** Both purposes can be served from ReScript:

#### Purpose 1: Pulumi entry point

Pulumi can point directly to the compiled ReScript output. Change `Pulumi.yaml`:
```yaml
main: src/Main.res.mjs
```

No `index.mjs` needed. The `let default = Pulumi.Pulumi.getOutputs()` in `Main.res` already produces the correct ESM default export.

#### Purpose 2: DCB registration

The `registerDcbConfig` function is already defined in ReScript (`PluginRuntime_Builder.res:33`). The only reason it's called from JS is to use `resolveModule` for absolute path resolution. This can be solved in two ways:

**Option A — Call `resolveModule` from ReScript:**

`resolveModule` is already bound in `Util_Bundle.res` as an `@module` external. The registration can happen directly in the plugin's `Main.res` or in a dedicated `DcbConfig.res`:

```rescript
// In catalog-aws/src/Main.res (before Platform.deployPlugin)
let pkg = "@reventlessdev/online-shop-hybrid-catalog/src"
let _ = PluginRuntime_Builder.registerDcbConfig(
  ~pluginName="Catalog",
  ~stateChangeSliceSpecPaths=[
    Util_Bundle.resolveModule(pkg ++ "/Product/StateChangeSlice/AddProduct.res.mjs"),
    Util_Bundle.resolveModule(pkg ++ "/Product/StateChangeSlice/ChangeProductName.res.mjs"),
    // ...
  ],
  (),
)
```

This works because `resolveModule` uses `createRequire` from the `Util_Bundle.mjs` file's context, not the caller's context. The `require.resolve` in Node.js follows the module resolution algorithm from the `require` function's base directory, which is `Util_Bundle.mjs`'s location inside `node_modules/@reventlessdev/reventless-aws/`. Since the target packages are also in `node_modules`, resolution succeeds regardless of which file calls it.

**Option B — Derive paths from Spec modules already imported in ReScript:**

The StateChangeSlice specs are already imported by the plugin's ReScript code (they're used to build the plugin). Instead of manually listing paths as strings, the framework could extract the module paths automatically at deploy time from the component tree. This would eliminate the registration step entirely, but requires deeper framework changes.

### Recommendation

Option A is straightforward and can be done immediately. Each plugin's `Main.res` calls `registerDcbConfig` with `resolveModule` paths before `deployPlugin`. The `index.mjs` files become unnecessary and can be replaced by pointing `Pulumi.yaml` directly at `Main.res.mjs`.

**Result**: Zero hand-written JavaScript files in application stacks.

---

## Summary

| Component | Current | Lines | Can be ReScript? | Residual JS |
|-----------|---------|-------|-----------------|-------------|
| `Util_Bundle.mjs` | esbuild runner | 155 | Yes, with bindings | None |
| `Util_EntryPoint.mjs` | code string generators | 838 | Yes, string concat | None |
| 15 `*HandlerFactory.mjs` | runtime functor wiring | ~1,400 | Yes, with runtime adapter pattern | ~3 lines (`patchSpecId`) |
| `HandlerFactoryHelpers.mjs` | DynamoDB scan + helpers | 150 | Yes, with AWS SDK bindings | None |
| 3 `index.mjs` (applications) | Pulumi entry + DCB registration | ~30 | Yes, move to Main.res | None |
| **Total** | | **~2,570** | | **~0-3 lines** |

**~2,570 lines of JS → ~0-3 lines of JS**, with everything else as type-safe ReScript that compiles and is checked against the actual framework types.

## Key Benefit

The core risk with the current approach: the handler factories manually reconstruct functor chains by name, so if `Aggregate_Callback.Make` changes its signature, these JS files silently break at runtime. Moving to ReScript makes the compiler catch these mismatches at build time. Additionally, eliminating the application-level `index.mjs` files means users never need to write or maintain JavaScript in their Reventless applications.

---

## The Deeper Problem: Code String Generation is Fundamentally Wrong

### Why the current approach fails even when ported to ReScript

Migrating `Util_EntryPoint.mjs` to ReScript (replacing `@module` externals with `let` functions returning strings) only changes the language the strings are written in. The strings themselves still contain:
- Hardcoded import paths like `"@reventlessdev/reventless-core/src/components/Aggregate/Aggregate_Callback.res.mjs"`
- Hardcoded export names like `"createCommandTopicHandler"`, `"Make"`
- Hardcoded function signatures and call patterns
- Hardcoded environment variable naming conventions

If any of these change in the framework, the string-generating functions must be manually updated to match. The ReScript compiler cannot check whether the string `"import { Make as AggregateCallbackMake } from ..."` actually corresponds to a real export. This is string programming — fundamentally unverifiable.

### Why code strings exist at all

The esbuild pipeline requires an **entry point file** for each Lambda. Each Lambda has different:
- Spec/Behavior/Mappings modules (user code)
- Environment variable names (infrastructure references)
- Factory function to call (component type)

Since each combination is unique, the current approach generates a unique entry point JS string for each Lambda, writes it to a temp file, and feeds it to esbuild.

### Better architecture: Generic compiled entry point + JSON config

Instead of generating code, use a **single compiled ReScript entry point module** per component type that:
1. Reads a JSON config from an environment variable at cold start
2. Uses `import()` (dynamic import) to load the factory and user modules by path
3. Calls the factory with the loaded modules and env var values

```
┌─────────────────────────────────────┐
│ Lambda Environment                   │
│                                      │
│ HANDLER_CONFIG = {                   │
│   "specModule": "/opt/.../Spec.mjs", │
│   "behaviorModule": "/opt/.../B.mjs",│
│   "eventLogTable": "MyTable",        │
│   "queueUrl": "https://sqs.../q"    │
│ }                                    │
│                                      │
│ ┌──────────────────────────────────┐ │
│ │ AggregateEntryPoint.res.mjs      │ │
│ │ (compiled ReScript, in layer)    │ │
│ │                                  │ │
│ │ 1. JSON.parse(HANDLER_CONFIG)    │ │
│ │ 2. import(config.specModule)     │ │
│ │ 3. import(config.behaviorModule) │ │
│ │ 4. call factory(spec, behavior,  │ │
│ │    config.eventLogTable, ...)    │ │
│ │ 5. export handler                │ │
│ └──────────────────────────────────┘ │
└─────────────────────────────────────┘
```

**Advantages:**
- **No code generation at all** — `Util_EntryPoint` disappears entirely
- **No esbuild step** — the entry point is pre-compiled and lives in the Lambda layer
- **Framework changes are caught by the compiler** — the entry point module imports the factory via normal ReScript `open`/`import`, not strings
- **Simpler deploy-time code** — the runtime builder just sets env vars (JSON config), no temp files or bundling
- **Faster `pulumi up`** — no esbuild invocation per Lambda (~0.5s per handler saved)

**The config types become the contract:**
```rescript
type aggregateConfig = {
  specModule: string,       // absolute path to compiled Spec module
  behaviorModule: string,   // absolute path to compiled Behavior module
  eventLogTable: string,    // DynamoDB table name (from env var at deploy time)
  queueUrl: string,         // SQS queue URL (from env var at deploy time)
}
```

**The entry point becomes real compiled code:**
```rescript
// AggregateEntryPoint.res — compiled into the Lambda layer
let handler = async (event, context) => {
  // Config loaded once at cold start
  let config = readConfig()  // JSON.parse(process.env.HANDLER_CONFIG)
  let spec = await dynamicImport(config.specModule)
  let behavior = await dynamicImport(config.behaviorModule)

  // This calls REAL compiled framework code — compiler-verified
  let ops = EventLog_Operations.Make(spec)(storageOps)
  let callback = Aggregate_Callback.Make(spec)(behavior)({eventLog: ops})
  let cmdCallback = CommandTopic_Callback.Make(spec)({commandsHandler: callback.handleCommands})

  await handleQueueEvent(queueRef, cmdCallback.handleJsonCommands)(event, context)
}
```

### What changes

| Aspect | Current (code strings) | Proposed (compiled entry point) |
|--------|----------------------|-------------------------------|
| Entry point | Generated JS string per Lambda | Single compiled module per component type, in layer |
| Module resolution | Hardcoded string paths | Dynamic `import()` from config |
| Factory wiring | String fragments calling functors by name | Real ReScript functor calls, compiler-checked |
| esbuild | Required per Lambda at deploy time | Not needed (entry point pre-compiled) |
| Deploy-time work | Generate string → write temp file → esbuild → archive | Set HANDLER_CONFIG env var (JSON) |
| Framework change resilience | Breaks silently at runtime | Compiler error at build time |

### Trade-offs

- **Dynamic import** (`import()`) is async — needs `await` at cold start. This adds a small latency cost (~10-50ms) but only on cold start. Already acceptable given current 500ms+ cold starts.
- **Module paths as data** — spec/behavior module paths still come from deploy time as strings. But the *framework* module paths (factory, callback, operations) are normal compiled imports, not strings.
- **One entry point per component type** — instead of one generated entry point per Lambda instance. The handler factories already abstract per-instance differences; the entry point just needs to load the right config.
- **Layer must include entry points** — the compiled entry point modules must be in the Lambda layer alongside the framework code. This is a natural fit.

### Relationship to handler factories

The handler factories (`AggregateHandlerFactory.mjs`, etc.) would still exist conceptually — they contain the functor wiring logic. But instead of being standalone JS files imported by generated code, they become **normal ReScript modules** called directly by the compiled entry point. The compiler verifies the functor chain at build time.

The factory pattern simplifies to:
```rescript
// In AggregateEntryPoint.res (compiled, in layer)
module AggregateFactory = {
  let create = (spec, behavior, storageOps, queueRef) => {
    let eventLogOps = EventLog_Operations.Make(spec)(storageOps)
    let aggCallback = Aggregate_Callback.Make(spec)(behavior)({eventLog: eventLogOps})
    let cmdCallback = CommandTopic_Callback.Make(spec)({commandsHandler: aggCallback.handleCommands})
    handleQueueEvent(queueRef, cmdCallback.handleJsonCommands)
  }
}
```

This is real code, not strings. If `Aggregate_Callback.Make` changes its signature, this file won't compile.

### Remaining challenge: Pulumi transitive imports

The entry point modules call framework functors (`EventLog_Operations.Make`, `Aggregate_Callback.Make`, etc.). Some of these modules currently import `@pulumi/pulumi` transitively. For the compiled entry point to work at Lambda runtime, these transitive imports must be eliminated.

This requires the same refactoring identified in the "Layer 3" section above:
- Split modules that mix deploy-time and runtime code
- Use `.resi` interface files to prevent Pulumi leakage
- Extract runtime-only variants of modules that currently depend on Pulumi

This refactoring is the hard part, but it's the **same work** regardless of whether we use code strings or compiled entry points. The compiled approach just makes it explicitly necessary rather than hiding it behind string-level indirection.
