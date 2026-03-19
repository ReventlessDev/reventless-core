# Pulumi Effect Serialization Error Analysis

## Problem

Deploying the online-shop-hybrid platform fails with:

```
error: Error serializing '(event, ctx) => Effect.Effect.runPro ...': Runtime.res.mjs(7,9)
captured variable 'Effect' which indirectly referenced
  FiberRuntime -> consoleTag -> function is not a bound function
```

Pulumi's `CallbackFunction` serializes Lambda handler closures to deploy them. The handler closure captures the `Effect` module, which transitively references `FiberRuntime` and `consoleTag` — non-serializable objects.

## Serialization Chain

### 1. Handler creation (runtime builders)

`AggregateRuntime_Builder_Micro.res` (and similar builders) transform handlers:

```rescript
~handler=handler->Pulumi.Output.apply(handler =>
  handler->RuntimeEnvironment.asEffectHandler->Runtime.runEffectHandler
)
```

### 2. Effect closure in `Runtime.runEffectHandler`

`reventless-core/src/adapter/Runtime/Runtime.res` (lines 9-17):

```rescript
let runEffectHandler = (handler): eventHandler<...> =>
  (event, ctx) =>
    handler(event, ctx)
    ->Effect.provideService(RequestContext.tag, RequestContext.test())
    ->Effect.runPromise
```

Compiled output (`Runtime.res.mjs`):

```javascript
import * as Effect from "effect";

function runEffectHandler(handler) {
  return (event, ctx) => Effect.Effect.runPromise(
    Effect.Effect.provideService(handler(event, ctx), ...)
  );
}
```

The returned function `(event, ctx) => Effect.Effect.runPromise(...)` captures the top-level `Effect` import.

### 3. Pulumi serialization boundary

`RuntimeEnvironment_Lambda.res` (line 23-34) passes the handler to `CallbackFunction`:

```rescript
let lambda =
  handler->Pulumi.Output.apply(handler =>
    Lambda.CallbackFunction.make(
      ~name,
      ~args=Lambda.CallbackFunction.Args.make(~callback=handler, ...),
    )
  )
```

Pulumi walks the `callback` closure, finds `Effect.Effect.runPromise`, follows it into `FiberRuntime`, and hits `consoleTag` which references an unbound function.

## Why Effect is non-serializable

Effect-TS's runtime (`FiberRuntime`) maintains global mutable state: fiber schedulers, loggers (including `consoleTag`), and supervision trees. These contain native objects, unbound functions, and circular references that Pulumi's V8 serializer cannot handle.

## Fix Options

### Option 1: Bundle handlers as code assets (recommended)

Replace `CallbackFunction` (inline closure serialization) with `aws.lambda.Function` + bundled code asset. The handler file is written to disk and uploaded as a zip/asset — no JS serialization needed.

**Pros**: Clean separation of deploy-time and runtime code. Works with any runtime library.
**Cons**: Requires a bundling step (esbuild) and restructuring how handlers are created. Significant refactor of `RuntimeEnvironment_Lambda` and all runtime builders.

### Option 2: Dynamic require inside the handler

Move `Effect` import inside the handler function body so it's resolved at Lambda runtime, not captured at serialization time:

```javascript
// Instead of:
import * as Effect from "effect";
(event, ctx) => Effect.Effect.runPromise(...)

// Use:
(event, ctx) => {
  const { Effect } = require("effect");
  return Effect.runPromise(...);
}
```

**Pros**: Minimal change — only `Runtime.res` needs modification.
**Cons**: Requires `%raw` or external JS wrapper since ReScript doesn't support dynamic imports inside function bodies. The `require("effect")` must resolve at Lambda runtime (from the Lambda Layer).

### Option 3: Serialize a handler reference, not the closure

Create the handler as a named export in a separate module. Pass the module path + export name to `CallbackFunction` instead of the closure itself. Pulumi supports `handler: "module.export"` style references on regular `Function` resources.

**Pros**: No serialization of closures at all.
**Cons**: Similar scope to Option 1 — needs restructuring of how handlers are wired.

## Option 2 Result: Confirmed Insufficient

After implementing Option 2 (`EffectRunner.mjs` dynamic require wrapper), the error moved one level deeper:

```
error: Error serializing function '<anonymous>': EffectRunner.mjs(20,17)
captured 'handler', a function defined at
  CommandTopicChannel_SQS_Runtime.res.mjs(8,9): which captured
    variable 'Effect' which indirectly referenced FiberRuntime -> consoleTag
```

The `handler` argument passed to `createHandler` is itself a function built in `CommandTopicChannel_SQS_Runtime` that captures `Effect`. Moving `Effect.runPromise` to a dynamic require doesn't help because the business logic handlers throughout the framework (`CommandTopicChannel_SQS_Runtime`, `EventLogStorage_DynamoDb_Runtime`, etc.) all use Effect internally.

**Every runtime handler in `reventless-aws/src/adapter/` that uses Effect will have this problem.** It is not possible to fix this by wrapping individual call sites — the entire handler closure graph references Effect.

## Recommendation

**Option 1 (bundled code assets) is the only viable fix.** Replace `CallbackFunction` (inline closure serialization) with `aws.lambda.Function` + bundled code asset:

1. At deploy time, bundle each Lambda handler into a self-contained JS file using esbuild
2. Upload the bundle as a Pulumi `AssetArchive` / `FileArchive`
3. Use `aws.lambda.Function` (not `CallbackFunction`) with `handler: "index.handler"` pointing to the bundled file
4. No closure serialization occurs — Pulumi only manages the infrastructure, not the JS code

**Scope**: Requires changes to `RuntimeEnvironment_Lambda.res`, the `Lambda.res` bindings, and all runtime builders that create `CallbackFunction` instances. This is a significant but well-scoped refactor — the handler logic itself doesn't change, only how it's packaged for Lambda.

**Alternative**: If the framework previously deployed successfully without Effect (before Effect was introduced), the other option is to remove Effect from all runtime handler code paths and use plain promises instead. This may be simpler if Effect was recently introduced and isn't deeply integrated.

## Consequences of Option 1 (Bundled Code Assets)

### Code Size Impact

**Current approach (CallbackFunction)**:
- Handler closure: ~1-2 KB serialized JavaScript
- Dependencies: served via Lambda Layer (67 MB uncompressed, 13 MB zipped)
- Total per Lambda: Layer (shared, uploaded once) + ~1-2 KB inline handler
- *But this doesn't work with Effect — blocked by serialization error*

**Bundled handlers + Layer (recommended hybrid)**:
- Handler bundle: ~5-50 KB per handler (esbuild tree-shakes, only handler code + glue)
- Dependencies: still served via Lambda Layer (unchanged)
- Total per Lambda: Layer (shared, uploaded once) + ~5-50 KB bundled handler
- **Net change: negligible increase per handler, same Layer**

**Bundled handlers without Layer (self-contained)**:
- Handler bundle: 5-50 MB per handler (includes Effect at 25 MB, reventless-core, utilities)
- No Layer needed
- Total per Lambda: 5-50 MB × N handlers — no deduplication
- **Not recommended**: 10 handlers × 25 MB = 250 MB vs 67 MB shared Layer

**Summary**: With the hybrid approach (bundled handlers + Layer), deployed code size stays essentially the same. Each handler goes from ~1-2 KB (serialized closure) to ~5-50 KB (esbuild bundle), but the Layer remains identical. The difference is imperceptible in practice.

### Advantages

1. **Eliminates all serialization issues permanently** — no closure walking, no dependency on Pulumi's V8 serializer. Works with Effect, or any other library with non-serializable internals.

2. **Enables tree-shaking** — esbuild only includes code the handler actually imports. Currently `CallbackFunction`'s `computeCodePaths` pulls in entire packages. The Layer already mitigates this, but bundled handlers could eventually replace the Layer entirely for smaller, faster Lambdas.

3. **Faster cold starts (potential)** — bundled handlers load a single file instead of traversing `node_modules`. Effect alone is 200+ modules in `dist/`. A tree-shaken bundle resolves imports at build time, reducing Lambda startup I/O.

4. **Deterministic deployments** — the bundle is built at deploy time from the exact source files. No runtime module resolution surprises. The deployed code is exactly what was built.

5. **Easier debugging** — source maps can be included in the bundle. Stack traces point to actual source locations rather than serialized closure fragments.

6. **Layer becomes optional** — once handlers are bundled, the Layer is an optimization (deduplication) rather than a requirement. Apps that only deploy 1-2 Lambdas could skip the Layer entirely.

### Consequences and Trade-offs

1. **Deploy-time build step** — each `pulumi up` runs esbuild to bundle handlers. This adds ~1-2 seconds total (esbuild is fast). Requires `esbuild` as a deploy-time dependency of `reventless-aws`.

2. **API change in runtime builders** — handler functions are no longer passed as `Pulumi.Output.t<closure>`. Instead, builders receive a module path + export name. This changes the interface for `RuntimeEnvironment_Lambda.make` and propagates to all runtime builders (well-scoped but touches many files).

3. **Module path resolution at deploy time** — the bundler needs to know the absolute path to each `*_Runtime.res.mjs` file. This requires a resolution strategy (e.g. `import.meta.resolve` or path conventions).

4. **Lambda Layer still needed** — without the Layer, each handler bundle would include the full Effect library (25 MB) and framework code. The Layer deduplicates this across all Lambdas in the account/region. Dropping the Layer is possible long-term but not advisable for multi-handler deployments.

5. **`fast-check` in the Layer** — the Layer currently includes `fast-check` (4.1 MB, property-based testing library) which is never used at runtime. This should be excluded regardless of the bundling approach.

### Current Lambda Layer Contents (for reference)

| Package | Size (uncompressed) | Purpose |
|---------|-------------------|---------|
| `effect` | 25 MB | Effect-TS runtime |
| `@reventlessdev/reventless-aws` | 6.5 MB | AWS adapters and handlers |
| `lodash` | 4.9 MB | Utility library |
| `fast-check` | 4.1 MB | Testing library (should be excluded) |
| `graphql` | 3.1 MB | GraphQL parser |
| `ramda` | 2.9 MB | Functional utilities |
| `@rescript/std` | 2.6 MB | ReScript standard library |
| **Total** | **67 MB** (13 MB zipped) | |

## Resolution: Bundled Lambda Handlers ✅

**Option 1 (bundled code assets) was implemented.** See `docs/plans/bundled-lambda-handlers.md` for the full implementation plan and progress.

All component types now have bundled Lambda handler variants that use `aws.lambda.Function` + esbuild-bundled code assets instead of `CallbackFunction`:

- Aggregate (Single, PerAggregate, Micro)
- ReadModel (Single, PerReadModel)
- AutomationSlice, StateViewSlice, OutboundTranslationSlice
- ExtensionPoint, PluginExtensionPoint
- Admin EventCollector (PluginRuntime)
- SideEffectHandler
- Task (PerBucket)
- Counter

**Performance**: Init 563ms, execution 239ms, 114MB memory. Cold start is acceptable.

**Non-bundled `CallbackFunction` paths are preserved** for backward compatibility but are superseded by the bundled variants. The `CallbackFunction` bindings remain in `rescript-pulumi-aws` as they are still used by:
- The non-bundled runtime path (`RuntimeEnvironment_Lambda.make`)
- Type aliases for Lambda event handler signatures
- AWS SDK bindings (SQS, S3, DynamoDB, Cognito event subscriptions)

## Files Involved

| File | Role |
|------|------|
| `reventless-core/src/adapter/Runtime/Runtime.res` | `runEffectHandler` — creates the non-serializable closure |
| `reventless-aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res` | Passes handler to `CallbackFunction.make` (serialization boundary) |
| `reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_Micro.res` | Calls `runEffectHandler` inside `Output.apply` |
| `rescript-pulumi-aws/src/Lambda/Lambda.res` | `CallbackFunction` bindings |
