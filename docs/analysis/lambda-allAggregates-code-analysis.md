# Lambda AllAggregates-6be80ef Code Analysis

**Date**: 2026-03-20
**Scope**: What code is deployed to the `AllAggregates` Lambda, why, what is dead/duplicated, and how to reduce size.

---

## 1. What Is Deployed

The `AllAggregates` Lambda consists of two parts:

### A. Bundled Code (esbuild output → `index.mjs`)

esbuild bundles a generated entry point into a single `index.mjs` file. The generated entry point imports:

1. **`AggregateHandlerFactory.mjs`** — reconstructs the CommandTopic handler chain
2. **`CommandGeneratorHandlerFactory.mjs`** — reconstructs the CommandGenerator handler chain
3. **`effect`** — Effect-TS runtime (the Effect runner)
4. **`RequestContext.res.mjs`** — correlation ID service tag
5. **`Spec_N` and `Behavior_N`** — one pair per registered aggregate (user's domain code)

Each import transitively pulls in:

| Dependency | Pulled In By | Purpose |
|---|---|---|
| `effect` (full library) | Entry point + factories | Effect runtime, service injection |
| `sury` | Spec modules (via `@schema` ppx) | JSON serialization/deserialization |
| `@reventlessdev/reventless-core` | Handler factories | Core framework (Aggregate_Callback, CommandTopic_Callback, EventLog_Operations) |
| `@reventlessdev/reventless-spec` | Core framework | Type system, Id module |
| `@reventlessdev/rescript-aws-sdk` | EventLogStorage_DynamoDb_Runtime | DynamoDB client wrappers |
| `@reventlessdev/rescript-effect` | Core framework | Effect-TS ReScript bindings |
| `@rescript/std` | All ReScript modules | ReScript standard library |
| `uuid` | Core framework (Id generation) | UUID v4 generation |

**esbuild externals**: Only `@aws-sdk/*` is externalized. Everything else is bundled into `index.mjs`.

### B. Lambda Layer (attached via `REVENTLESS_LAYER_ARN`)

The layer is built by `reventless-layer-builder` from `@reventlessdev/reventless-aws` and **all its prod dependencies** (excluding Pulumi, AWS SDK, OpenTelemetry, and sigstore scopes). It contains:

- **9,778 files** across **~170 unique packages** (44 MB uncompressed, 13 MB zip)
- Installed at `/opt/nodejs/node_modules/` in the Lambda runtime

---

## 2. The Core Problem: Complete Duplication

**esbuild bundles everything except `@aws-sdk/*` into `index.mjs`. The layer also contains all those same packages.** The bundled code and the layer are 100% redundant for the packages they share.

This means the AllAggregates Lambda loads:
- `effect` twice (bundled + layer)
- `sury` twice
- `@reventlessdev/reventless-core` twice
- `@rescript/std` twice
- etc.

The layer exists because it was originally built for the **legacy CallbackFunction path** (Pulumi closure serialization), where Lambda code wasn't bundled — it needed `node_modules` available at runtime via the layer. With the switch to esbuild bundling, the layer became redundant for bundled handlers.

**Impact**: The Lambda deployment package is unnecessarily large. Cold starts load duplicated modules. The layer zip must be rebuilt and uploaded on dependency changes.

---

## 3. Dead Code in the Bundle

### 3.1 effect (full library bundled)

esbuild bundles the **entire `effect` package** because it doesn't tree-shake CJS-style Effect internal modules effectively. The AllAggregates handler only uses:
- `Effect.runPromise`
- `Effect.provideService`
- `Effect.flatMap` / `Effect.map` / `Effect.gen` (inside callbacks)
- `Effect.tryPromise` (inside DynamoDB operations)

Unused Effect modules bundled: Stream, Channel, STM, Fiber, Layer, Metric, Queue, PubSub, Schedule, Schema, JSONSchema, Cron, DateTime, Pool, etc. This is likely **>70% of the `effect` bundle size**.

### 3.2 sury (schema library)

The full sury library is bundled. At runtime, only `S.parseOrThrow` and `S.serializeOrThrow` (and their underlying schema definitions) are used. Validation, arbitrary generation, and pretty-printing code is dead.

### 3.3 Unused reventless-core modules

The entire `@reventlessdev/reventless-core` package is pulled in, but AllAggregates only uses:
- `Aggregate_Callback.Make`
- `CommandTopic_Callback.Make`
- `EventLog_Operations.Make`
- `RequestContext` (service tag)
- `Id.String` (patched in factory)

Modules like ReadModel, Plugin, Counter, ExtensionPoint, StateChangeSlice, etc. are dead code in this context.

### 3.4 HandlerFactoryHelpers.mjs `scanByTableName`

This function (DynamoDB scan with filter) is in `HandlerFactoryHelpers.mjs` but is only used by ReadModel/Counter handlers, not by AggregateHandlerFactory. It gets bundled into AllAggregates anyway because the factory imports from the same helpers module.

---

## 4. Dead Code in the Layer

The layer is built from `@reventlessdev/reventless-aws` prod dependencies. Several packages in the layer are **never needed at Lambda runtime**:

### 4.1 Deploy-time-only packages (Pulumi bindings)

| Package | Why It's There | Why It's Dead |
|---|---|---|
| `@reventlessdev/rescript-pulumi-aws` | Prod dep of reventless-aws | Only used at Pulumi deploy time, never at Lambda runtime |
| `@reventlessdev/rescript-pulumi-pulumi` | Prod dep of reventless-aws | Only used at Pulumi deploy time |
| `@reventlessdev/reventless-infra` | Prod dep of reventless-aws | Infrastructure definitions, not runtime |

### 4.2 npm/package management tooling

These are dependencies of `@reventlessdev/reventless-aws` because it depends on packages that depend on npm tooling (likely `@npmcli/arborist` or similar):

| Package | Size Estimate |
|---|---|
| `@npmcli/agent`, `@npmcli/fs`, `@npmcli/git`, `@npmcli/package-json`, `@npmcli/promise-spawn` | ~100 KB |
| `@gar/promise-retry` | small |
| `cacache`, `make-fetch-happen`, `minipass-*` (6 packages), `ssri` | ~200 KB |
| `hosted-git-info`, `npm-install-checks`, `npm-normalize-package-bin`, `npm-package-arg`, `npm-pick-manifest`, `validate-npm-package-name` | ~100 KB |
| `pacote`-related: `minipass-fetch`, `socks`, `socks-proxy-agent`, `http-proxy-agent`, `https-proxy-agent`, `agent-base` | ~150 KB |
| `spdx-exceptions`, `spdx-expression-parse`, `spdx-license-ids` | ~50 KB |

### 4.3 SSH/crypto packages

| Package | Why Dead |
|---|---|
| `ssh2` | SSH client — used by `@reventlessdev/rescript-ssh2` for deploy-time operations (e.g., Cloner), not runtime aggregate handling |
| `@reventlessdev/rescript-ssh2` | ReScript bindings for ssh2 |
| `tweetnacl`, `bcrypt-pbkdf` | Dependencies of ssh2 |
| `asn1` | ASN.1 parser, dependency of ssh2 |

### 4.4 CSV/GraphQL packages (context-dependent)

| Package | When Needed |
|---|---|
| `@fast-csv/format`, `@fast-csv/parse`, `fast-csv` | Only needed by Cloner/CSV export features |
| `@reventlessdev/rescript-fast-csv` | ReScript bindings for fast-csv |
| `graphql`, `jsonschema2graphql` | Only needed if GraphQL API (AppSync) is used |
| `lodash` (full) + 7 `lodash.*` packages | Transitive dep of fast-csv/graphql — full lodash is massive (~500 KB) |

### 4.5 Development/build artifacts

| Package | Why Dead |
|---|---|
| `esprima` | JavaScript parser — not needed at runtime |
| `acorn` | JavaScript parser — not needed at runtime |
| `source-map`, `source-map-support` | Source map support — not needed in production |
| `cjs-module-lexer` | CJS module analysis — not needed at runtime |
| `execa`, `cross-spawn` | Process spawning — not needed in Lambda |
| `fast-check`, `pure-rand` | Property-based testing — explicitly excluded in config but still present? |
| `ramda` | Functional utility library — check if actually used at runtime |

### 4.6 `foo.js` (mystery file)

A bare `foo.js` file exists at the root of the layer's `node_modules/`. This is likely an artifact.

---

## 5. Why the Serialized (CallbackFunction) Code Was Dramatically Smaller

With Pulumi's `CallbackFunction`, the code was **serialized closures** — Pulumi inspected the JavaScript closure graph and serialized only the functions reachable from the handler callback. This naturally:

1. **Tree-shook aggressively** — only captured functions that were actually called in the closure chain
2. **Didn't bundle `effect` at all** — the Effect runner and pipe functions were captured as closures, not as a bundled library
3. **Didn't bundle `sury`** — schema functions were captured as pre-built closures
4. **Skipped all deploy-time code** — Pulumi only serialized runtime-reachable code

The tradeoff was that CallbackFunction serialization was **fragile** — Effect-TS's internal `Symbol` usage and class-based runtime caused serialization failures, which is why the switch to esbuild bundling was necessary.

---

## 6. Recommendations to Reduce Code Size

### 6.1 Fix the layer/bundle duplication (HIGH IMPACT)

**Option A: Externalize layer packages from esbuild** (recommended)

Change `Util_Bundle.mjs` to externalize packages that are in the layer:

```javascript
external: [
  "@aws-sdk/*",
  "effect",
  "sury",
  "@reventlessdev/*",
  "@rescript/*",
  "uuid",
  "hash-object",
  // ... other layer packages
]
```

This would reduce the esbuild bundle from potentially megabytes to **just the generated entry point + handler factory code + user domain code** (tens of KB). The layer provides the shared dependencies.

**Option B: Remove the layer entirely**

If each Lambda bundles its own code, the layer is redundant. Removing it saves the layer upload/management overhead. But each Lambda would carry its own copy of `effect`, `sury`, etc.

**Recommendation**: Option A. The layer amortizes cold start time across Lambda invocations (shared layer cache), and one layer serves all Lambda functions in the deployment.

### 6.2 Clean up the layer (MEDIUM IMPACT)

Add more exclusions to the layer builder:

```rescript
excludeScopes: [
  "pulumi", "types", "opentelemetry", "aws-sdk", "smithy", "sigstore",
  "npmcli",       // ← ADD: npm tooling
],
excludeModules: [
  "aws-sdk", "sury-ppx", "fast-check",
  "ssh2", "tweetnacl", "bcrypt-pbkdf", "asn1",  // ← ADD: SSH deps
  "esprima", "acorn", "source-map", "source-map-support", "cjs-module-lexer",  // ← ADD: build tools
  "execa", "cross-spawn", "shebang-command", "shebang-regex",  // ← ADD: process spawning
  "ramda",  // ← ADD: check if actually needed
  "lodash",  // ← ADD: if only lodash.* subpackages are needed
],
```

Also add post-processing to delete tests, examples, docs:
```rescript
postProcess: Dict.fromArray([
  ...existing,
  (">ssh2", deleteTests),  // ssh2/test, ssh2/examples
  (">lodash", deleteDist),  // lodash.min.js, core.min.js
])
```

**Estimated savings**: 2-4 MB uncompressed from the layer.

### 6.3 Enable esbuild minification (MEDIUM IMPACT)

Currently `minify: false` in `Util_Bundle.mjs`. Enabling minification:

```javascript
minify: true,
```

Would significantly reduce bundle size (typically 40-60% for `effect`-heavy code). The `sourceCodeHash` ensures Pulumi detects changes correctly.

### 6.4 Consider esbuild tree-shaking improvements (LOW IMPACT, HIGH EFFORT)

esbuild's tree-shaking works best with ESM. The `effect` package ships ESM, but some internal patterns defeat tree-shaking. Possible approaches:
- Use `effect/Effect` direct import instead of `effect` barrel export
- Mark specific heavy modules as side-effect-free in esbuild config

### 6.5 Split `reventless-aws` dependencies (ARCHITECTURAL)

The root cause of layer bloat is that `@reventlessdev/reventless-aws` has **both deploy-time and runtime dependencies** in a single `dependencies` field. The layer builder extracts all prod deps, so deploy-time-only packages (Pulumi bindings, SSH, npm tooling) end up in the runtime layer.

Options:
- Split into `reventless-aws-runtime` (only runtime deps) and `reventless-aws` (deploy + runtime)
- Add a `layerDependencies` field that the layer builder reads instead of full prod deps
- Use the existing filter mechanism more aggressively (current approach, just needs more exclusions)

---

## 7. Size Estimates

### Measured bundle sizes (simulated AllAggregates, 1 aggregate)

| Config | Size | Modules Bundled |
|---|---|---|
| OLD (external: `@aws-sdk/*` only, minify: false) | **1.04 MB** | 673 |
| NEW (externals list, minify: false) | **5.4 KB** | 7 |
| NEW (externals list + minify: true) | **2.7 KB** | 7 |

### Projected total deployed sizes

| Component | Current | After externalize + minify + layer cleanup |
|---|---|---|
| esbuild bundle (index.mjs) | ~1 MB | ~3-5 KB |
| Layer zip | 13 MB | ~8-10 MB (estimated, pending rebuild) |
| **Total deployed** | **~14 MB** | **~8-10 MB** |

The biggest win is externalizing layer packages from esbuild — a **99.7% reduction** in bundle size. The bundle now contains only the generated entry point and handler factory wiring code.

---

## 8. Summary

| Finding | Impact | Fix Effort | Status |
|---|---|---|---|
| esbuild bundles everything the layer already provides | ~1 MB wasted per Lambda | Low — add externals list | ✅ Fixed (1.04 MB → 2.7 KB) |
| Layer contains deploy-time packages (Pulumi, npm, ssh2) | ~2-4 MB wasted in layer | Low — add exclusions | ✅ Fixed (30+ exclusions added) |
| esbuild minification disabled | ~50% bundle bloat | Trivial — flip flag | ✅ Fixed |
| Full `effect` library bundled (only ~30% used) | ~1 MB dead code | N/A — solved by externals | ✅ Fixed (externalized to layer) |
| Full `lodash` in layer (unused) | ~500 KB dead code | Low — add exclusion | ✅ Fixed (excluded from layer) |
| `reventless-aws` mixes deploy-time and runtime deps | Root cause of layer bloat | High — package restructure | Deferred (mitigated by exclusions) |
