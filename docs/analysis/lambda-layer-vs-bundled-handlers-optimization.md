# Analysis: Lambda Layer vs Bundled Handlers — What's Where and What Can Be Optimized

## Overview

Reventless uses a **Lambda Layer + Code Asset** deployment model:

- **Lambda Layer** (`/opt/nodejs/node_modules/`): Contains the entire framework (reventless-core, reventless-aws, reventless-spec, reventless-infra, reventless-interop), all ReScript bindings, and runtime dependencies (effect, sury, @smithy/*, uuid, etc.)
- **Code Asset** (`/var/task/node_modules/`): Contains only the user's business logic modules (Specs, Behaviors, Mappings)
- **Entry Points**: 13 compiled `*EntryPoint.res` files live in the layer. Each reads `HANDLER_CONFIG` from env vars at cold start, dynamically imports user modules from the code asset, and wires functor chains.

The layer is built by `reventless/reventless-layer-builder/`, which uses npm Arborist to resolve the dependency tree of `@reventlessdev/reventless-aws`, then filters, extracts, and post-processes packages into a zip.

**Current layer size**: CI warns at >40 MB (Lambda limit: 50 MB unzipped = ~250 MB).

---

## Part 1: What's in the Bundled Handlers (Entry Points)

All 13 entry points live in the layer at `@reventlessdev/reventless-aws/src/adapter/Runtime/*EntryPoint.res.mjs`. They are thin wiring modules — they don't contain business logic, only:

1. `HANDLER_CONFIG` parsing from environment variables
2. Dynamic `import()` calls to load user modules from `/var/task/node_modules/`
3. Build-verified `@module` imports of framework functors from the layer
4. Functor chain wiring (e.g., `EventLog_Operations.Make` → `Aggregate_Callback.Make` → `CommandTopic_Callback.Make`)
5. Event routing logic (group by source ARN, extract correlation ID)

### Entry Point Inventory

| Entry Point | Trigger | User Modules | Framework Imports |
|---|---|---|---|
| `AggregateEntryPoint` | SQS + AppSync | Spec, Behavior | EventLog_Operations, Aggregate_Callback, CommandTopic_Callback, CommandGenerator_Callback, EventLogStorage_DynamoDb_Runtime, CommandTopicChannel_SQS_Runtime, effect/Effect, RequestContext |
| `DcbCommandTopicEntryPoint` | SQS + AppSync | StateChangeSlice Specs[], DcbEventLog? | StateChangeSlice_Callback, DcbEventLog_Operations, DcbEventLogStorage_DynamoDb_Runtime, CommandTopicChannel_SQS_Runtime, Message, Id, DcbTag, effect/Effect, effect/Stream |
| `ReadModelEntryPoint` | DynamoDB Stream | Spec, Mappings | ReadModel_Callback, EventCollectorChannel_DynamoDbStream_Runtime, QueryDbStorage_DynamoDb_Runtime, effect/Effect, RequestContext |
| `StateViewSliceEntryPoint` | DynamoDB Stream | Specs[], DcbEventLog? | Projection, EventCollectorChannel_DynamoDbStream_Runtime, QueryDbStorage_DynamoDb_Runtime, sury/S, effect/Effect, effect/Stream, RequestContext |
| `AutomationSliceEntryPoint` | DynamoDB Stream | Specs[], DcbEventLog? | AutomationSlice_Callback, OutboundTranslationSlice_Callback, EventCollectorChannel_DynamoDbStream_Runtime, QueryDbStorage_DynamoDb_Runtime, CommandTopicChannel_SQS_Runtime, sury/S, effect/Effect, effect/Stream, RequestContext |
| `CounterEntryPoint` | DynamoDB Stream | target Spec, Mappings | Counter_Callback, EventMapper_Callback, QueryDbStorage_DynamoDb_Runtime, CommandTopicChannel_SQS_Runtime, Util_DynamoDbStream_Runtime, sury/S |
| `EventMapperEntryPoint` | DynamoDB Stream | target Spec, Mappings | EventMapper_Callback, EventCollectorChannel_DynamoDbStream_Runtime, CommandTopicChannel_SQS_Runtime, Id, effect/Effect, RequestContext |
| `SideEffectEntryPoint` | DynamoDB Stream | SideEffect modules[] | SideEffectHandler_Callback, EventCollectorChannel_DynamoDbStream_Runtime, effect/Effect, RequestContext |
| `ExtensionPointEntryPoint` | SQS | Spec, Mappings | ExtensionPoint_Callback, CommandTopic_Callback, CommandTopicChannel_SQS_Runtime, effect/Effect, RequestContext |
| `PluginExtensionPointEntryPoint` | SQS | None (framework-only) | PluginExtensionPoint_Plugin, ExtensionPoint_Callback, CommandTopic_Callback, CommandTopicChannel_SQS_Runtime, Util_PluginMessage_Runtime, ScheduledPublisher_CloudWatchEvents_Runtime, effect/Effect, RequestContext |
| `AdminEventCollectorEntryPoint` | SQS | None (framework-only) | PluginExtensionPoint_Plugin, ExtensionPoint_Operations, EventCollectorChannel_SQS_Runtime, Util_SNS_Runtime, Util_PluginMessage_Runtime, ScheduledPublisher_CloudWatchEvents_Runtime, GraphQL_Stitcher, AdminApi, PluginReadModelSpec, sury/S, effect/Effect, effect/Stream, @aws-sdk/client-appsync (dynamic import), RequestContext |
| `TaskBucketEntryPoint` | S3 | callback module | TaskBucket_S3_Runtime, CommandTopicChannel_SQS_Runtime |
| `HeartbeatEntryPoint` | CloudWatch Events | None (framework-only) | CommandTopicChannel_SQS_Runtime, Message, PluginExtensionPointSpec, sury/S |

### Key observation about entry points

The entry points are already optimized — they import **only what they need** from the framework via specific `@module` externals. They don't import entire packages; they cherry-pick individual functions. This is possible because ReScript compiles to individual `.res.mjs` files with named exports, and ESM tree-shakes at the import level.

However, the **Lambda Layer** contains the entire framework regardless. Every Lambda function that uses the layer pays the full cold-start cost of having all framework code available, even if a given handler only needs a fraction of it.

---

## Part 2: What's in the Lambda Layer

The layer builder (`reventless/reventless-layer-builder/src/Main.res`) starts from `@reventlessdev/reventless-aws` and resolves its entire production dependency tree, then filters out known build-time/deploy-time packages.

### Included Packages

#### Reventless Framework (5 packages)
| Package | Runtime Use | Deploy-Time Use |
|---|---|---|
| `reventless-aws` | Entry points, DynamoDB/SQS/SNS/S3 runtime adapters | Pulumi adapter builders, Lambda factory |
| `reventless-core` | Callbacks, Operations, Message, Projection, Admin | Builders, Adapters, Pulumi utilities |
| `reventless-spec` | Id types, DcbTag, component type specs | Aggregate/ReadModel/Plugin specs |
| `reventless-infra` | PluginExtensionPointSpec | Infrastructure type definitions |
| `reventless-interop` | JS interop helpers | JS interop helpers |

#### ReScript Bindings (included in layer)
| Package | Runtime Use | Deploy-Time Use |
|---|---|---|
| `rescript-aws-sdk` | DynamoDB, SQS, SNS, S3 client bindings | Same |
| `rescript-effect` | Effect/Stream runtime | Same |
| `rescript-pulumi-pulumi` | **None at runtime** | Pulumi core bindings |
| `rescript-pulumi-aws` | **None at runtime** | Pulumi AWS provider bindings |
| `rescript-uuid` | UUID generation | Same |
| `rescript-fast-csv` | CSV stream export (Cloner only) | Same |
| `rescript-hash-object` | Object hashing | Same |
| `rescript-node-streams` | Node.js streams | Same |
| `rescript-ssh2` | **None at runtime** (Cloner runs on Fargate, not Lambda) | SSH2 for Cloner |

#### JavaScript Runtime Libraries
| Package | Purpose | Required by |
|---|---|---|
| `effect` | Effect system (Effect, Stream, Layer, etc.) | All entry points |
| `sury` | JSON schema validation/serialization | DCB, automation, state view entry points + specs |
| `@smithy/*` (~37 packages) | AWS SDK protocol implementations | rescript-aws-sdk → DynamoDB/SQS/SNS/S3 |
| `@rescript/runtime` | ReScript runtime library | All compiled ReScript code |
| `uuid` | UUID generation | Message.uuid |

#### Packages of Uncertain Runtime Necessity
| Package | Notes |
|---|---|
| `esbuild` | **No longer needed** — was used for deploy-time bundling, now replaced by compiled entry points |
| `@aws-crypto/*` | Cryptographic utilities, transitive from @smithy |
| `ansi-*`, `chalk`, `debug` | CLI/logging utilities — may be transitive from effect or other deps |
| `graceful-fs`, `yargs`, `escalade` | Filesystem/CLI utilities — likely transitive, not directly used |
| `json5` | JSON5 parser — likely transitive |
| `fast-json-stable-stringify` | Deterministic JSON — likely transitive from hash-object |
| `@standard-schema` | Schema validation standard — transitive from sury |
| `jsonschema2graphql` | GraphQL schema generation — **deploy-time only** (used by reventless-spec for GraphQL schema gen from JSON Schema) |

### Excluded from Layer (correctly)

| Scope/Module | Reason |
|---|---|
| `@pulumi/*` | Deploy-time only (Pulumi CLI/SDK) |
| `@aws-sdk/*` | Provided by Lambda runtime |
| `@types/*` | TypeScript type definitions |
| `@opentelemetry/*` | Optional tracing |
| `@sigstore/*`, `@npmcli/*`, `@gar/*` | npm infrastructure |
| `sury-ppx` | Build-time PPX compiler (~93 MB) |
| `rescript` | ReScript compiler (build-time) |
| `ssh2`, `tweetnacl`, `bcrypt-pbkdf`, `asn1` | SSH stack (Cloner/Fargate only) |
| `esprima`, `acorn`, `source-map*`, `cjs-module-lexer` | Build/parse tools |
| `execa`, `cross-spawn`, `shebang-*` | Process spawning |
| `cacache`, `make-fetch-happen`, `ssri`, `minipass-*`, etc. | npm infrastructure |
| `pure-rand`, `@glennsl/rescript-jest`, `fast-check` | Testing |
| `ramda`, `lodash`, `graphql` | Unused at runtime |

### Post-Processing (size savings)

| Target | Action | Savings |
|---|---|---|
| All rescript-dependent packages | Delete `*.res`, `*.resi` source files | Moderate |
| `reventless-core` | Delete `coverage/`, `scripts/`, `test-helper/`, `tests/` | Moderate |
| `effect` | Delete `src/` (TypeScript source) | **~7.5 MB** |
| `rescript-effect`, `rescript-fast-csv`, `fast-csv` | Delete tests/examples/benchmarks | Small |

---

## Part 3: What Could Be Removed from the Layer

### High-Impact Removals

#### 1. `rescript-pulumi-pulumi` and `rescript-pulumi-aws` — **Deploy-time only**

These packages provide ReScript bindings for Pulumi and are used extensively at deploy time (`pulumi up`) but **never at Lambda runtime**. No entry point imports from them.

**Why they're included**: They're listed as production `dependencies` in `reventless-core/package.json` and `reventless-aws/package.json`, so Arborist pulls them in. The current framework mixes deploy-time and runtime code in the same packages.

**Size impact**: The compiled `.res.mjs` files for these bindings are moderate in size, plus they may pull in transitive dependencies.

**Removal approach**: Add to `excludeModules` in the layer builder config.

#### 2. `rescript-fast-csv`, `rescript-node-streams`, `rescript-hash-object`, `rescript-ssh2` — **Cloner-only or unused at Lambda runtime**

- `rescript-fast-csv` + `rescript-node-streams`: Used by the Cloner (runs on Fargate, not Lambda). The `CsvStream.res` utility in reventless-core is only used by the Cloner export.
- `rescript-hash-object`: Used for object hashing. Grepping the entry points shows **no entry point imports it**. It's a transitive dependency used by some core module, but may not be reachable from any entry point code path.
- `rescript-ssh2`: Already excluded as a module (`ssh2`), but the ReScript bindings package itself might still be included.

**Removal approach**: Add `rescript-fast-csv`, `rescript-node-streams`, `rescript-hash-object` to `excludeModules`. Verify `rescript-ssh2` is fully excluded (both the bindings and the underlying `ssh2` package).

#### 3. `esbuild` — **No longer needed**

The analysis `esbuild-bundling-process.md` confirms esbuild was used for deploy-time bundling but has been replaced by compiled entry points. If it's still in the layer, it should be excluded.

**Size impact**: esbuild includes a native binary — potentially **10-20 MB**.

**Removal approach**: Add `esbuild` to `excludeModules`.

#### 4. `jsonschema2graphql` — **Deploy-time only**

Listed as a dependency of `reventless-spec` for generating GraphQL schemas from JSON Schema at deploy time. Already in `excludeModules` — verify it's actually being excluded.

#### 5. CLI/build utilities that are transitives: `yargs`, `escalade`, `graceful-fs`, `chalk`, `ansi-*`, `debug`, `json5`

These are likely transitive dependencies of packages like `effect` or Arborist leftovers. If they're not imported by any runtime code path, they can be excluded.

**Size impact**: Small individually, but they add up.

**Removal approach**: Audit each by checking if any included package actually imports them at runtime. Add confirmed unused ones to `excludeModules`.

### Medium-Impact Removals

#### 6. Deploy-time code within framework packages

The biggest structural issue is that `reventless-core` and `reventless-aws` mix deploy-time and runtime code in the same package:

- **Deploy-time code in reventless-core**: All `*_Builder.res` files (~20+ files), `*_Adapter.res` files (~12 files), `Util_Pulumi.res`, `Util_Adapter.res`, `AdapterDeploytime.res`, `Builder_Helpers.res`, `Interstack.res`, `OutputLogger.res`, `Cloner.res`, `CsvStream.res`, `ResourceQuery.res`
- **Deploy-time code in reventless-aws**: All `*Runtime_Builder_*.res` files, `RuntimeEnvironment_Lambda.res`, adapter builders

These files are all compiled to `.res.mjs` and included in the layer, even though they are never imported at Lambda runtime. The entry points only import `*_Callback.res.mjs`, `*_Operations.res.mjs`, `*_Runtime.res.mjs`, `Projection.res.mjs`, `Message.res.mjs`, `RequestContext.res.mjs`, and a few admin modules.

**Removal approach**: This can't be solved by `excludeModules` since it's intra-package. Options:
1. **Post-process**: Add patterns to delete deploy-time `.res.mjs` files from the layer (e.g., `**/*_Builder.res.mjs`, `**/*_Adapter.res.mjs`)
2. **Package split**: Separate runtime code into dedicated packages (e.g., `reventless-core-runtime`, `reventless-aws-runtime`)

### Lower-Impact Removals

#### 7. `@smithy/*` packages — consider Lambda runtime provision

The comment in `Main.res` (lines 28-30) explains why `@smithy/*` is NOT excluded despite `@aws-sdk/*` being excluded:

> `@smithy/* is provided by the Lambda runtime, but ESM imports from layer code cannot resolve it via NODE_PATH. Include it in the layer so ESM resolution finds it under /opt/nodejs/node_modules/.`

This is a significant chunk of the layer (~37 packages). If ESM resolution could be fixed (e.g., by using `createRequire` or a custom loader), `@smithy/*` could be dropped.

**Size impact**: Potentially **large** — the @smithy scope is the AWS SDK's protocol implementation.

**Removal approach**: Investigate ESM resolution workarounds. This is a non-trivial change.

---

## Part 4: What Could Be Optimized in Bundled Handlers

### Current State

The bundled handlers (entry points) are already well-optimized:
- Each imports only the specific functions it needs via `@module` externals
- No unused framework code is imported
- Dynamic imports keep user code out of the layer
- `HANDLER_CONFIG` JSON env var avoids deploy-time code generation

### Potential Optimizations

#### A. Per-handler layers (not recommended)

Creating a separate layer per handler type would minimize cold-start overhead — each handler would only load the modules it actually needs. However:
- **Complexity**: 13 separate layer builds and version management
- **Storage**: 13 separate zip files to maintain
- **Diminishing returns**: ESM only loads modules that are actually `import()`-ed; unused files in the layer don't affect runtime unless they're imported

**Verdict**: Not worth the complexity. ESM lazy-loads modules on import.

#### B. Bundle handlers with esbuild instead of using layer (trade-off analysis)

Instead of a shared layer, each handler could be bundled with esbuild into a self-contained code asset that includes only the framework modules it imports.

**Pros**:
- Each handler contains exactly the code it needs — no wasted layer space
- No layer version management
- Simpler deployment pipeline
- Potentially faster cold starts (smaller code to parse)

**Cons**:
- Larger code assets (each bundles framework code)
- Duplicate framework code across handlers
- Loses the "update layer once, all handlers get new framework" benefit
- esbuild must handle ESM→ESM bundling with dynamic imports preserved

**Verdict**: Worth considering for the future, but the current layer approach is simpler and the layer update mechanism is valuable during active development.

#### C. Tree-shake the layer at build time

Instead of shipping the entire npm package contents, the layer builder could use esbuild or rollup to bundle only the modules reachable from the 13 entry points. This would automatically exclude all deploy-time code.

**Pros**:
- Significant size reduction
- No manual exclude list maintenance
- Automatically adapts as entry points change

**Cons**:
- Dynamic imports (`import('/var/task/...')`) must be preserved
- Some framework modules use `Obj.magic` and `%raw` which may confuse tree-shakers
- Adds build complexity

**Verdict**: This is the most promising optimization if layer size becomes a concern.

---

## Part 5: Is Optimization Worth It?

### Current Situation

- Layer size is under the 40 MB warning threshold (well under the 250 MB unzipped Lambda limit)
- CI already warns at >40 MB, giving early notice of bloat
- Post-processing already removes the biggest offenders (effect `src/` = 7.5 MB, ReScript source files)
- Excluded modules list already covers most known unnecessary packages

### When Optimization Becomes Necessary

1. **Layer approaching 50 MB zip / 250 MB unzipped**: Immediate need — some removals become mandatory
2. **Cold start times becoming a concern**: Profile first — the bottleneck is usually DynamoDB connections and import resolution, not layer size
3. **Adding new dependencies**: Each new runtime dep should be audited against the "is it needed at Lambda runtime?" question

### Recommended Priority

| Priority | Action | Effort | Impact |
|---|---|---|---|
| **P0 — Quick wins** | Verify `esbuild` is excluded; add to `excludeModules` if not | Trivial | Potentially 10-20 MB |
| **P1 — Low effort** | Add `rescript-pulumi-pulumi`, `rescript-pulumi-aws` to `excludeModules` | Trivial | Moderate (removes deploy-time bindings + transitives) |
| **P1 — Low effort** | Add `rescript-fast-csv`, `rescript-node-streams`, `rescript-hash-object` to `excludeModules` | Trivial (verify no runtime use first) | Small-moderate |
| **P2 — Medium effort** | Audit and exclude CLI/utility transitives (`yargs`, `chalk`, `debug`, etc.) | Need to trace dependency tree | Small |
| **P2 — Medium effort** | Post-process to delete `*_Builder.res.mjs`, `*_Adapter.res.mjs` from framework packages | Add patterns to post-process config | Moderate |
| **P3 — High effort** | Investigate ESM resolution for `@smithy/*` to allow exclusion | May require custom ESM loader or `createRequire` | Large |
| **P3 — High effort** | Tree-shake layer using bundler | New build pipeline step | Large |
| **P4 — Structural** | Split runtime/deploy-time code into separate packages | Major refactor | Long-term solution |

### Conclusion

The layer is already reasonably well-optimized. The most impactful quick wins are:

1. **Exclude `esbuild`** if still present (was previously used for deploy-time bundling, now replaced)
2. **Exclude Pulumi binding packages** (`rescript-pulumi-pulumi`, `rescript-pulumi-aws`) — purely deploy-time
3. **Exclude Cloner-only packages** (`rescript-fast-csv`, `rescript-node-streams`, potentially `rescript-hash-object`)

These are all single-line additions to `excludeModules` in `Main.res`. Beyond these, the law of diminishing returns applies — the remaining optimizations require progressively more effort for less impact, and should only be pursued if the layer approaches size limits or cold start profiling reveals module loading as a bottleneck.

The bundled handlers themselves are already lean and well-structured. The entry-point-per-component-type pattern with `@module` cherry-picking is close to optimal for the current architecture.
