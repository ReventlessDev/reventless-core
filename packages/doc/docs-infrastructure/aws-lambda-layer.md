# AWS Lambda Layer

The reventless-aws Lambda layer provides shared runtime dependencies to all Lambda functions deployed by the framework. Instead of bundling the entire framework into every function, esbuild marks framework packages as **external** and the Lambda layer supplies them at runtime under `/opt/nodejs/node_modules/`.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  Lambda Function (/var/task/)                           │
│                                                         │
│  index.mjs (esbuild bundle)                             │
│    ├── user domain code (Spec, Behavior)    ← bundled   │
│    ├── import ... from "effect/Effect"       ← external  │
│    ├── import ... from "@reventlessdev/..." ← external  │
│    └── import ... from "@rescript/..."       ← external  │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  Lambda Layer (/opt/nodejs/node_modules/)               │
│                                                         │
│    @reventlessdev/reventless-aws/                       │
│    @reventlessdev/reventless-core/                      │
│    @reventlessdev/rescript-effect/                       │
│    @rescript/runtime/                                    │
│    effect/                                               │
│    sury/                                                 │
│    uuid/                                                 │
│    hash-object/                                          │
│    ...transitive runtime dependencies                    │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  AWS Lambda Runtime                                     │
│    @aws-sdk/* (provided by AWS)                         │
└─────────────────────────────────────────────────────────┘
```

## How Bundling Works

### esbuild Configuration

Lambda function code is bundled by esbuild at deploy time (`Util_Bundle.mjs`). The following packages are marked **external** — they are NOT included in the bundle and must be present in the layer (or the AWS runtime) at execution time:

```javascript
external: [
  "@aws-sdk/*",           // provided by AWS Lambda runtime
  "effect",               // layer-provided
  "effect/*",             // deep imports from effect
  "sury",                 // layer-provided
  "sury/*",               // deep imports from sury
  "@reventlessdev/*",     // framework packages — layer-provided
  "@rescript/*",          // ReScript runtime — layer-provided
  "@standard-schema/*",   // layer-provided
  "uuid",                 // layer-provided
  "hash-object",          // layer-provided
]
```

This list must stay in sync with what the layer builder produces. If a package is external here but missing from the layer, Lambda functions will crash at import time.

### Two Bundling Modes

**`bundleHandler(entryPoint, exportName)`** — wraps a single compiled `.res.mjs` handler:
```javascript
import { handleQueueEvent } from "/abs/path/handler.res.mjs";
export const handler = handleQueueEvent;
```

**`bundleEntryPoint(entryPointCode)`** — bundles a generated JavaScript string (used for complex multi-handler Lambdas). The code string is written to a temp file and fed to esbuild.

Both modes produce a `{code: AssetArchive, sourceCodeHash: string}` tuple for Pulumi.

### Package Specifiers vs. Absolute Paths

This distinction is critical for correct bundling:

- **Package specifiers** (e.g., `"@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateHandlerFactory.mjs"`) match the `@reventlessdev/*` external pattern → esbuild leaves them as-is → resolved from the layer at runtime.

- **Absolute paths** (e.g., `/Users/.../node_modules/@reventlessdev/.../AggregateHandlerFactory.mjs`) do NOT match external patterns → esbuild follows and inlines the file. Any transitive `@reventlessdev/*` imports inside that file then become top-level externals in the output — but they resolve from `/var/task/`, not from the layer.

**Rule:** framework module paths (`factoryModule`, `requestContextModule`) must be package specifiers. User domain paths (`specModulePath`, `behaviorModulePath`) are resolved to absolute paths so esbuild bundles them.

### Deep Imports for `effect`

The `effect` package barrel (`import { Effect } from "effect"`) re-exports everything, including testing utilities that transitively require `fast-check`. Since `fast-check` is excluded from the layer, barrel imports crash at runtime.

All code must use **deep imports**:

```javascript
// correct — loads only the Effect module
import { Effect } from "effect/Effect";
import { Stream } from "effect/Stream";

// wrong — loads the barrel, pulls in fast-check
import { Effect, Stream } from "effect";
```

This applies to:
- **ReScript bindings** (`rescript-effect`): use `@module("effect/Effect")`, not `@module("effect")`
- **Handler factories** (hand-written `.mjs`): `import { Effect } from "effect/Effect"`
- **Generated entry points** (`Util_EntryPoint.mjs`): template literals generate deep imports

## Entry Point Generation

`Util_EntryPoint.mjs` generates Lambda handler code for each component type. The generated code:

1. Imports the handler factory from the layer (`@reventlessdev/reventless-aws/...`)
2. Imports `RequestContext` from the layer (`@reventlessdev/reventless-core/...`)
3. Imports user Spec/Behavior modules (bundled via absolute paths or user package specifiers)
4. Reads infrastructure details from environment variables (table names, queue URLs)
5. Constructs handlers at cold start, dispatches SQS/DynamoDB events to them

### Generator Functions

| Function | Component | Trigger |
|----------|-----------|---------|
| `generateAggregateEntryPoint` | Aggregate | SQS (CommandTopic) + AppSync (CommandGenerator) |
| `generateDcbCommandTopicEntryPoint` | DCB CommandTopic | SQS + AppSync |
| `generateReadModelEntryPoint` | ReadModel | DynamoDB Stream (EventCollector) |
| `generateStateViewSliceEntryPoint` | StateViewSlice | DynamoDB Stream |
| `generateAutomationSliceEntryPoint` | AutomationSlice | DynamoDB Stream |
| `generateOutboundTranslationSliceEntryPoint` | OutboundTranslationSlice | DynamoDB Stream |
| `generateExtensionPointEntryPoint` | ExtensionPoint | SQS |
| `generatePluginExtensionPointEntryPoint` | PluginExtensionPoint | SQS |
| `generateAdminEventCollectorEntryPoint` | Admin EventCollector | SQS |
| `generateSideEffectEntryPoint` | SideEffectHandler | DynamoDB Stream |
| `generateTaskBucketEntryPoint` | Task | S3 |
| `generateCounterEntryPoint` | Counter | DynamoDB Stream |
| `generateHeartbeatEntryPoint` | Heartbeat | EventBridge Schedule |
| `generateCommandGeneratorEntryPoint` | CommandGenerator | AppSync direct |
| `generateEventMapperEntryPoint` | EventMapper | DynamoDB Stream |

### Generated Code Pattern

```javascript
import { createCommandTopicHandler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateHandlerFactory.mjs";
import { Effect } from "effect/Effect";
import * as RequestContext from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import * as Spec_0 from "/abs/path/to/ItemSpec.res.mjs";
import * as Behavior_0 from "/abs/path/to/ItemBehavior.res.mjs";

const runEffect = (correlationId, effect) =>
  effect
    .pipe(Effect.provideService(RequestContext.tag, { correlationId: correlationId || "unknown" }))
    .pipe(Effect.runPromise);

const commandTopicHandlers = new Map([
  [process.env.HANDLER_0_QUEUE_ARN, createCommandTopicHandler({
    specModule: Spec_0,
    behaviorModule: Behavior_0,
    eventLogTableName: process.env.HANDLER_0_TABLE,
    queueUrl: process.env.HANDLER_0_QUEUE_URL,
  })],
]);

export const handler = async (event, context) => {
  // route SQS event to correct handler by queue ARN
  // ...
};
```

After esbuild bundling:
- `Spec_0` and `Behavior_0` are inlined (absolute paths)
- `@reventlessdev/*`, `effect/Effect`, `RequestContext` remain as external imports → resolved from layer

## Lambda Runtime Integration

### Layer ARN

Lambda functions reference the layer via the `REVENTLESS_LAYER_ARN` environment variable, read at deploy time:

```rescript
// rescript-pulumi-aws/src/Lambda/Lambda.res
@val external reventlessLayerArn: option<string> = "process.env.REVENTLESS_LAYER_ARN"
```

`RuntimeEnvironment_Lambda.res` attaches the layer to every bundled Lambda:

```rescript
let layers =
  Lambda.reventlessLayerArn
  ->Option.map(arn => [arn->Pulumi.Input.make])
  ->Option.getOr([])
  ->Pulumi.Input.make
```

The current layer ARN is stored in AWS SSM Parameter Store at
`/reventless/layer-arn/{stack}` (e.g. `/reventless/layer-arn/alpha`), written by
CI after each layer publish. The deploy workflow reads it back into
`REVENTLESS_LAYER_ARN`. Parameters are regional — CI writes and reads them in the
same region as the deploy. It is no longer committed to the repository.

### ESM Module Resolution

Lambda functions use ESM format (`index.mjs`). Node.js ESM resolution differs from CommonJS:

- **CJS** (`require`): respects `NODE_PATH` → Lambda sets `NODE_PATH=/opt/nodejs/node_modules` → layer packages found
- **ESM** (`import`): does NOT use `NODE_PATH` → walks ancestor directories from the importing file

AWS Lambda runtimes (Node.js 18+) handle this by making layer packages discoverable to ESM imports. The layer structure at `/opt/nodejs/node_modules/` is resolved correctly by the Lambda runtime's module loader.

## Layer Builder

### Location

`reventless/layer-builder/` — private package, not published.

### How It Works

The builder (`DependencyBundler.res`) executes these steps:

1. **Clean** — delete previous `layer/` directory
2. **Install** — download `@reventlessdev/reventless-aws@<version>` from GitHub Package Registry via Pacote
3. **Resolve tree** — use `@npmcli/arborist` to compute ideal dependency tree with `preferDedupe: true`, production dependencies only
4. **Filter** — depth-first traversal, apply inclusion/exclusion rules (see [Filtering Rules](#filtering-rules))
5. **Extract** — copy matching packages to `layer/nodejs/node_modules/`
6. **Post-process** — delete unnecessary files from extracted packages (tests, sources, etc.)
7. **Zip** — create `reventless-layer.zip`

### Configuration (`Main.res`)

```rescript
let config: DependencyBundler_Config.t = {
  sourcePackageName: "@reventlessdev/reventless-aws",
  sourcePackageVersion,            // from REVENTLESS_AWS_VERSION env var
  pathToLayerData,                 // builder/layer/
  pathToSavedDependencies,         // builder/layer/nodejs/node_modules
  excludeScopes: [...],
  includeModules: [...],
  excludeModules: [...],
  registryOpts: ...,               // GitHub Package Registry auth
  postProcess: ...,                // per-package file cleanup
}
```

### Filtering Rules

**Excluded scopes** (entire `@scope/*`):

| Scope | Reason |
|-------|--------|
| `@pulumi/*` | deploy-time infrastructure only |
| `@types/*` | TypeScript type definitions |
| `@opentelemetry/*` | optional observability |
| `@aws-sdk/*` | provided by AWS Lambda runtime |
| `@smithy/*` | AWS SDK internals (provided at runtime) |
| `@sigstore/*` | code signing (deploy-time) |
| `@npmcli/*` | npm CLI tools |
| `@gar/*` | artifact registry tools |

**Excluded modules** (specific packages):

| Category | Packages |
|----------|----------|
| Build tools | `aws-sdk`, `sury-ppx`, `esprima`, `acorn`, `source-map`, `source-map-support`, `cjs-module-lexer` |
| Testing | `fast-check`, `pure-rand` |
| SSH (Cloner) | `ssh2`, `tweetnacl`, `bcrypt-pbkdf`, `asn1` |
| Process spawning | `execa`, `cross-spawn`, `shebang-command`, `shebang-regex` |
| npm infrastructure | `cacache`, `make-fetch-happen`, `ssri`, `minipass-*`, `socks*`, `*-proxy-agent`, `hosted-git-info`, `npm-*`, `validate-npm-*`, `spdx-*` |
| Unused at runtime | `ramda`, `lodash`, `graphql`, `jsonschema2graphql` |

**Explicitly included** (overrides exclusion):

| Package | Reason |
|---------|--------|
| `@rescript/runtime` | transitive dep of `rescript` (excluded as build tool), but required at runtime by all compiled ReScript code |

**Filter precedence** (`DependencyBundler_Filter.res`):
1. In `includeModules` → include
2. Marked `dev`, `optional`, `devOptional`, `peer` → exclude
3. Scope in `excludeScopes` → exclude
4. Name in `excludeModules` → exclude
5. All parent dependencies excluded → exclude (`DependentExcluded`)
6. Otherwise → include

### Post-Processing

After extraction, per-package cleanup removes files unnecessary at runtime:

| Matcher | Action | Savings |
|---------|--------|---------|
| `>rescript` (any package depending on rescript) | Delete `**/*.res`, `**/*.resi` | ~5 MB |
| `@reventlessdev/reventless-core` | Delete `coverage/`, `scripts/`, `test-helper/`, `tests/` | — |
| `@reventlessdev/rescript-effect` | Delete `tests/` | — |
| `effect` | Delete `src/` (TypeScript sources) | ~7.5 MB |
| `@reventlessdev/rescript-fast-csv`, `fast-csv` | Delete `tests/`, `test/`, `examples/`, `benchmark/`, `docs/` | — |

### Output

```
reventless-layer.zip
└── nodejs/
    └── node_modules/
        ├── @reventlessdev/
        │   ├── reventless-aws/
        │   ├── reventless-core/
        │   ├── reventless-spec/
        │   ├── reventless-infra/
        │   ├── reventless-interop/
        │   ├── rescript-effect/
        │   ├── rescript-uuid/
        │   ├── rescript-hash-object/
        │   ├── rescript-fast-csv/
        │   ├── rescript-node-streams/
        │   └── rescript-pulumi-pulumi/
        ├── @rescript/
        │   └── runtime/
        ├── effect/
        │   └── dist/         (src/ deleted by post-process)
        ├── sury/
        ├── uuid/
        ├── hash-object/
        └── ...transitive deps
```

Final size: ~30–40 MB uncompressed. Lambda limit is 50 MB per layer (uncompressed).

## CI/CD

### Workflow: `.github/workflows/build-lambda-layer.yml`

**Triggers:**

| Event | Condition | Version Source |
|-------|-----------|----------------|
| Tag push | `@reventlessdev/reventless-aws@*` | extracted from tag |
| Branch push | `main`, `beta`, `alpha` + path `reventless/layer-builder/**` | `reventless-aws/package.json` |
| Manual dispatch | `workflow_dispatch` | input parameter |

**Steps:**
1. Checkout + setup Node.js 22.17.1
2. `npm install` (with GitHub Package Registry auth)
3. Build layer: `cd reventless/layer-builder && npm run build`
4. Verify artifact size (warn >40 MB)
5. Publish to AWS Lambda: `aws lambda publish-layer-version --layer-name reventless-aws`
6. Store new layer ARN in SSM: `aws ssm put-parameter --name /reventless/layer-arn/{stack}`
7. Upload zip as GitHub release asset
8. Append layer ARN to release notes

**Secrets required:**
- `AWS_LAYER_ACCESS_KEY_ID` / `AWS_LAYER_SECRET_ACCESS_KEY` — IAM user `reventless-ci-layer-publisher`
- `GITHUB_TOKEN` — for npm registry and release asset upload

**IAM policy** (`iam-policy.json`): scoped to `arn:aws:lambda:*:*:layer:reventless-aws*` with `PublishLayerVersion` and `GetLayerVersion` permissions, plus `ssm:PutParameter` on `arn:aws:ssm:*:*:parameter/reventless/layer-arn/*` so the publish job can store the ARN. The deploy credentials need the matching `ssm:GetParameter` on the same path to read it back.

### When to Rebuild

The layer must be rebuilt when:
- Framework packages (`@reventlessdev/*`) change in ways that affect runtime code
- Dependencies are added/removed/updated
- Handler factory files (`.mjs`) are modified
- The layer builder configuration changes

The layer does NOT need rebuilding for:
- User domain code changes (Spec, Behavior) — these are bundled into function code
- Deploy-time infrastructure changes (Pulumi resources)
- Changes to excluded packages (build tools, testing)

## Keeping External List and Layer in Sync

The esbuild external list (`Util_Bundle.mjs`) and the layer builder configuration (`Main.res`) must stay synchronized:

| esbuild external | Layer builder | Notes |
|-----------------|---------------|-------|
| `@aws-sdk/*` | excluded (scope) | provided by AWS Lambda runtime |
| `effect`, `effect/*` | included (dependency of reventless-aws) | `src/` deleted by post-process |
| `sury`, `sury/*` | included (dependency) | — |
| `@reventlessdev/*` | included (source package + deps) | tests/scripts deleted |
| `@rescript/*` | `@rescript/runtime` explicitly included | `rescript` itself excluded (build tool) |
| `@standard-schema/*` | included (dependency of sury) | — |
| `uuid` | included (dependency) | — |
| `hash-object` | included (dependency) | — |

If a package is added to esbuild externals, it must also be present in the layer. If a package is removed from the layer, it must be removed from esbuild externals (or bundled).

## Troubleshooting

### "Cannot find package 'X' imported from /var/task/index.mjs"

Package `X` is in esbuild's external list but missing from the layer. Either:
- Add it to the layer builder (ensure it's a dependency of `@reventlessdev/reventless-aws` or listed in `includeModules`)
- Remove it from esbuild's external list (it will be bundled instead)
- If `X` is `@reventlessdev/*`: verify the framework module path is a package specifier, not an absolute path (absolute paths cause esbuild to inline the file but leave its transitive imports as externals)

### "Cannot find package 'fast-check'"

Something is importing from the `effect` barrel instead of using deep imports. Check:
- Handler factory files (`*HandlerFactory.mjs`): must use `import { Effect } from "effect/Effect"`
- Generated entry points (`Util_EntryPoint.mjs`): template literals must generate `"effect/Effect"`
- ReScript bindings (`rescript-effect`): must use `@module("effect/Effect")`, not `@module("effect")`

### Layer ARN mismatch

If a deploy uses an old layer ARN:
- Check `REVENTLESS_LAYER_ARN` environment variable during `pulumi up`
- Verify the SSM parameter has the latest ARN: `aws ssm get-parameter --name /reventless/layer-arn/{stack} --query Parameter.Value --output text` (in the deploy region)
- Manual override: set `REVENTLESS_LAYER_ARN=arn:aws:lambda:...` before deploying, or pass the `layer-arn` workflow input

### Layer size exceeds 40 MB

- Review recently added dependencies
- Add large unused packages to `excludeModules` in `Main.res`
- Add post-process handlers to strip non-essential files
- Check if new transitive dependencies introduced bulk

### Cold start performance

The layer is extracted once per Lambda container init. Larger layers increase cold start time. Keep the layer lean by:
- Excluding build/test/documentation files via post-processing
- Excluding packages unused at runtime
- Using deep imports to avoid loading unnecessary module trees

## File Reference

| File | Purpose |
|------|---------|
| `reventless/layer-builder/src/Main.res` | Layer builder config (exclusions, post-processing) |
| `reventless/layer-builder/src/DependencyBundler.res` | Build orchestration |
| `reventless/layer-builder/src/DependencyBundler_Config.res` | Config type definition |
| `reventless/layer-builder/src/DependencyBundler_Filter.res` | Inclusion/exclusion logic |
| `reventless/layer-builder/src/DependencyBundler_PostProcess.res` | Per-package file cleanup |
| `reventless/aws/src/util/Util_Bundle.mjs` | esbuild bundling (external list) |
| `reventless/aws/src/util/Util_Bundle.res` | ReScript bindings for bundling |
| `reventless/aws/src/util/Util_EntryPoint.mjs` | Lambda entry point code generation |
| `reventless/aws/src/util/Util_EntryPoint.res` | Entry point config types |
| `reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res` | Lambda deployment (layer attachment) |
| `rescript/rescript-pulumi-aws/src/Lambda/Lambda.res` | `REVENTLESS_LAYER_ARN` binding |
| `.github/workflows/build-lambda-layer.yml` | CI/CD layer build + publish |
| SSM `/reventless/layer-arn/{stack}` | Current layer ARN (written by CI, per stack/region) |
