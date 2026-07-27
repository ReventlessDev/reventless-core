# Plan: Convert AWS Lambda entry points to type-checked ReScript (`_Ops` split)

## Status: Phase 1 COMPLETE — all four Group-2 handlers converted to ReScript

The two originally-deferred Postgres handlers (`PgMigrationEntryPoint`,
`PgChangeFeedRelayEntryPoint`) are now converted too, completing all four
Group-2 conversions. See **§4 → Deferred-handler conversion** below for that
second pass (2026-07-27); the four presign/geocoder/Heartbeat/PluginExtensionPoint
conversions from the first pass are recorded here:

All four first-pass conversions are deployed to alpha (pushed; CI published
reventless-aws → rebuilt the layer → deployed online-shop-hybrid, Lambdas last
modified 2026-07-27 ~03:13–03:15 UTC) and confirmed functional at runtime:

- **presign + geocoder** — converted from Pulumi `CallbackFunction` to compiled
  EntryPoints with type-checked `_Ops` handlers (commits `39134f2f8`,
  `6bf9b7c6b`). Presign: clean post-redeploy (4–22 ms, no errors) and drove 16
  image uploads in a live seed run; the earlier `Cannot read properties of
  undefined (reading 'use')` 502 was the pre-redeploy version and does not
  recur. Geocoder: direct-invoked `q=Berlin` → `200` with real coordinates
  (module loads, no SDK skew, `geo:SearchPlaceIndexForText` IAM + AWS Location
  both work).
- **`HeartbeatEntryPoint` + `PluginExtensionPointEntryPoint`** — converted from
  hand-written `.mjs` shells to pure-ReScript entry points (`.res` → tracked
  `.res.mjs`) in commit `1bffd6785`; old shells deleted, builders repointed.
  Root build zero-warning green; all reventless-aws suites pass; both compiled
  import graphs verified `@pulumi`-free (92 modules walked). **Validated on
  alpha 2026-07-27** via CloudWatch: the `.res` Heartbeat Lambdas fire every
  5 min (clean `START→END`, 30–100 ms, no cold-start crash), and
  `PlatformPluginExtPointCmdHandler` processes `Heartbeat(Catalog/Ordering/
  PlatformInspector)` directives, runs `ScheduleOps`, and drains its queue
  cleanly.
- **Postgres handlers (now converted, 2026-07-27 second pass):** the two
  VPC-bound Postgres handlers (`PgMigrationEntryPoint`,
  `PgChangeFeedRelayEntryPoint`) were originally deferred (not laptop-validatable,
  woven into RDS/VPC plumbing). They have since been converted to pure-ReScript
  entry points; the `.mjs` shells are deleted. Full write-up in **§4 →
  Deferred-handler conversion**. A latent `@pulumi/pulumi` cold-start leak in
  the relay's runtime graph was found and fixed in the same pass.

**Note (pre-existing, unrelated to this plan):** alpha currently runs duplicate
Lambda generations (e.g. two `CatalogPluginHeartbeat`, two
`PlatformPluginExtPointCmdHandler`), both firing/draining — the known
"2 connected plugin versions" issue (retire hook inert). Not a side effect of
the entry-point conversion; the new generation's Lambdas are the ones validated
above.

**Date:** 2026-07-27 (validated same day)

---

## 0. How this started — the seeding 502

`pnpm run seed` against alpha aborted with:

```
product image upload for prd-001 failed: presign failed with HTTP 502: Internal Server Error
```

The presign handler's own error path returns **HTTP 400** (`presign_failed`), so
a **502** meant the Lambda crashed *before* returning — a cold-start failure of
the `UploadPresignService` Function URL Lambda (`eu-west-1`), not an application
error. Diagnosing it uncovered a whole class of latent deploy bugs.

---

## 1. Root cause — the "Frankenstein SDK"

The presign service was a Pulumi **`Lambda.CallbackFunction`** (serialize-closure).
`serialize-closure` inlines the deploy machine's version-specific AWS SDK
internals into `__index.js`, then deep-`require`s the transitives from
**independently-versioned sources that disagree**:

- `@aws-sdk/*` → resolved from the managed `nodejs22.x` runtime (`/var/runtime`).
- `@smithy/*` → resolved from the Lambda **layer** (`/opt/nodejs`).
- the closure body itself → whatever the **deploy workspace** had pinned.

Two symptoms, one disease (both surface as a 502 from the Function URL):

1. **Missing nested module.** `Cannot find module
   '@aws-sdk/s3-request-presigner/node_modules/@aws-sdk/signature-v4-multi-region/…'`.
   Version skew — `@reventlessdev/rescript-aws-sdk` pulls the newer
   `@aws-sdk@3.10xx` family (hoisted), while `reventless-aws` pins `3.970.0`, so
   pnpm **nested** the `3.970.0` copy of `signature-v4-multi-region`. Pulumi
   captured that pnpm-nested path literally; it does not exist in the Lambda.
   (The earlier `5b9394897` "keep full @smithy scope in the layer" fix addressed
   the *previous* missing module in this same chain, not this one.)

2. **`middlewareStack` undefined.** After patching (1), `new S3Client()` throws
   `TypeError: Cannot read properties of undefined (reading 'use')`. The layer
   ships `@smithy/smithy-client@4.14.14`, whose base `Client` constructor no
   longer sets `this.middlewareStack`, but the closure's inlined `client-s3@3.970.0`
   subclass assumes it does. The layer's `@smithy` had **drifted ahead** of the
   `@smithy` the closure was built against (the layer is a fresh install of the
   published `reventless-aws`; the workspace lockfile pins an older `@smithy`).

**Why an EntryPoint fixes it:** a compiled handler that imports `@aws-sdk/*` as
**bare specifiers** lets the resolve-hook load the entire SDK — client *and* its
own matching `@smithy` — from **one** source (`/var/runtime`), with only
`@smithy`/`@reventlessdev/*` coming from the layer. No serialized closure, no
mixed versions. This is the framework's existing EntryPoint model.

### Secondary bugs found along the way

- **No CloudWatch Logs permission.** Both the presign and geocoder execution
  roles had *only* `s3:PutObject` / `geo:SearchPlaceIndexForText` — **no logs**.
  Every failure was invisible (no log group ever created). `makeWithDefaultPolicy`
  grants only the trust policy, not logs; callers must add
  `logs:CreateLogGroup/CreateLogStream/PutLogEvents` in their inline RolePolicy.
- **Swallowed error.** The presign `catch` returned `presign_failed` with no
  `Console.error`, so even with logs the cause was hidden.

---

## 2. The three EntryPoint tiers (and why the string one is weakest)

Framework Lambda handler code exists in three forms:

| Tier | Count in `reventless-aws` | Compiler-checked? |
|---|---|---|
| Inline JS string in a `.res` (`handlerCode` / `makeHandlerCode`) | 6 | ❌ no — a typo fails at runtime; backtick-escaping is itself a hazard |
| Hand-written `.mjs` file | 16 | ❌ no `@ts-check` either, but a real file with editor/lint support |
| Runtime-pure ReScript `*_Ops.res` → `.res.mjs` | 4 (Aggregate, DCB, QueryDb, CommandGenerator) | ✅ **yes — full ReScript type-checking** |

The initial presign/geocoder fix used the **inline-string** tier (mirroring
`Platform_UIFragments_Lambda.res`). That drew the objection that drove this plan:
*why pack code into unchecked strings?* The answer: the handler must live outside
the deploy-time module (rules below), and the string was the laziest way to do
it. The **`_Ops.res` tier is the strongest** and is what we standardised on.

### The two hard rules a handler must satisfy

1. **Not a serialized Pulumi closure** — that is what caused the Frankenstein-SDK
   crash.
2. **Must not statically import Pulumi at runtime** — a compiled module that
   `open PulumiAws` / imports `@pulumi/*` at top level pulls Pulumi into the
   Lambda's cold-start graph (the documented "pulumi leaks into runtime" bug).
   ESM hoists all imports, so even an unexecuted deploy-time `make` in the same
   module loads `@pulumi/*`. Hence the handler lives in a **Pulumi-free** module.

### The `_Ops` pattern (what we shipped for presign/geocoder)

- `X_Ops.res` — runtime handler. Typed `@module("@aws-sdk/…")` externals; **no**
  `open PulumiAws`; **no** `%raw` (bind `process.env`, `node:crypto`, `Buffer` as
  typed externals). Exports `handler`. Fully type-checked.
- `X.res` — deploy-time `make` (Pulumi) only. Builds the Lambda via:
  ```
  let packageDirs = Dict.fromArray([
    ("@reventlessdev/reventless-aws",
     Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws")),
  ])
  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/…/X_Ops.res.mjs",
    ~packageDirs,
  )
  ```
  then `Lambda.Function.make(~handler="index.handler", ~runtime="nodejs22.x",
  ~code, ~sourceCodeHash, ~layers=[Lambda.reventlessLayerArn], …)` with env
  `NODE_OPTIONS = Util_Bundle.esmLoaderNodeOptions`,
  `ESM_FALLBACK_DIRS = Util_Bundle.esmFallbackDirs`, and the role's inline policy
  **including logs**. Keep the existing `FunctionUrl.make` (public services).

### How resolution works at runtime (the resolve-hook)

`buildCodeArchive` writes `index.mjs` = `export { handler } from "<entryPointModule>"`,
ships `register-hook.mjs` + `layer-resolver.mjs`, and bundles the named packages
(bundling `@reventlessdev/reventless-aws` **auto-co-bundles `effect`**). At cold
start `NODE_OPTIONS=--import …/register-hook.mjs` installs an ESM `resolve` hook
that, on `ERR_MODULE_NOT_FOUND` for a **bare** specifier, retries against each dir
in `ESM_FALLBACK_DIRS` (`/opt/nodejs/node_modules` then `/var/runtime/node_modules`).
So: the compiled `_Ops.res.mjs` resolves from bundled `/var/task`; its
`@rescript/runtime` from the layer; its `@aws-sdk/*` from the managed runtime —
each internally consistent.

**Why bundle the whole package** rather than resolve the `_Ops` module from the
layer's copy of `reventless-aws`: the layer lags (it is the *published*
`reventless-aws`, which does not yet contain new/edited `_Ops` files). Bundling
ships current source. Cost: ~2.1 MB archive vs. ~4 KB for the inline string —
the same cost every other EntryPoint already pays.

### ReScript gotchas hit while writing the `_Ops` handlers

- Array **rest-patterns** (`[_, x, ..._]`) are not supported → use `Array.get`.
- `JSON.parseExn` and `String.sliceToEnd` are **deprecated** (warning 3) →
  `JSON.parseOrThrow` and `String.slice(~start, ~end)`.
- Zero-warnings policy: `pnpm run build 2>&1 | grep -E "Warning|error"` must be
  empty before commit.

### Validation method (reuse for every conversion)

The deployed archive can be reproduced locally and deployed to the live alpha
Lambda without a full `pulumi up`:

1. Build the archive shape: `index.mjs` re-export + `register-hook.mjs` +
   `layer-resolver.mjs` + a filtered copy of `reventless-aws` (only
   `*.mjs`/`*.js`/`package.json`, skipping `node_modules`/`lib`/`tests`/…) +
   `effect`.
2. `aws lambda update-function-code` + `update-function-configuration` (set
   `handler=index.handler`, env incl. `NODE_OPTIONS`/`ESM_FALLBACK_DIRS`); the
   layer is already attached.
3. Invoke and assert the response.
4. Temporarily attach `AWSLambdaBasicExecutionRole` for logs while validating;
   **detach after** (the real fix grants logs via the role's own inline policy).

The next real deploy reconciles the manual patch (resource is replaced:
`CallbackFunction` → `Function`).

---

## 3. Why presign/geocoder can be 100% ReScript — and the `.mjs` handlers cannot (all)

**Presign/geocoder are fully ReScript** because every effect they perform is
**statically known**: a fixed AWS SDK call, an env read, crypto/UUID. Each maps
to a typed external, so the whole handler type-checks. Nothing they touch has an
identity or shape discovered only at runtime.

The 16 `.mjs` entry points split into two groups (evidence: `grep -c "import("`):

### Group 1 — dynamic-import handlers (12 of 16)

`AggregateEntryPoint`, `AutomationSliceEntryPoint`, `CounterEntryPoint`,
`DcbCommandTopicEntryPoint`, `EventCollectorEntryPoint`, `EventMapperEntryPoint`,
`ExtensionPointEntryPoint`, `PgQueryResolverEntryPoint`, `ReadModelEntryPoint`,
`SideEffectEntryPoint`, `StateViewSliceEntryPoint`, `TaskBucketEntryPoint`.

Their core job is `import(specifier)` of **user/plugin code** (aggregate
behaviors, projections, task callbacks) where `specifier` comes from
`HANDLER_CONFIG` at cold start (`dynamicImport(config.callbackModule)`). That
boundary is **inherently untyped** — you load a module the compiler has never
seen and read `.callback`/`.mappings` off it. ReScript *can* do a runtime-specifier
`import()`, but only via an untyped external + `Obj.magic`, which repo convention
says to keep in a companion `.mjs`. So **full conversion buys ~no type-safety at
the seam.** The worthwhile move here is the one the framework already does for the
two most complex — hoist the *pure* logic into a typed `*_Ops.res`
(`AggregateEntryPoint_Ops`, `DcbCommandTopicEntryPoint_Ops`), keeping a thin
untyped `.mjs` seam.

### Group 2 — no-dynamic-import handlers (4 of 16) — the real candidates

`HeartbeatEntryPoint` (38 LOC), `PgMigrationEntryPoint` (40),
`PgChangeFeedRelayEntryPoint` (57), `PluginExtensionPointEntryPoint` (127).

These are the true analogues of presign/geocoder: they mostly **wire
already-typed ReScript modules** and read env — and doing that in JS actively
*discards* the types. E.g. `HeartbeatEntryPoint` calls
`reverseConvertToJsonOrThrow(payload, commandSchema)` and builds a `Message`
entirely untyped, though `commandSchema`, `uuid`, and `publishJsons` are all
typed ReScript. Converting these to pure-ReScript `_Ops` handlers is a real
safety **gain**, not cosmetic.

**Conclusion:** "convert them all the same way" — **Group 2 yes** (adds safety;
small files); **Group 1 no, not fully** (the dynamic-import seam must remain an
untyped `.mjs` boundary — conventions endorse that; the only win is incremental
`_Ops` extraction).

---

## 4. Plan

### Phase 1 — convert Group-2 handlers to ReScript (EXECUTED, scoped down)

**Reassessment before execution.** Closer reading changed the plan's §4 in three
ways (user approved the reduced scope: Heartbeat + PluginExtensionPoint,
validated via CI deploy):

- These four are **not** presign/geocoder-like standalone services: they lean on
  the shared shim `HandlerFactoryHelpers.mjs` (structured JSON logging mirroring
  ReScript's `Logger`, the `runEffect` Effect/RequestContext dispatch boundary,
  `makeQueueRef`/`makeTableRef`/`patchSpecId`/`scanByTableName`, envelope-field
  extraction) and publish into live platform plumbing. Only Heartbeat is
  laptop-invokable with acceptable side effects; the two Pg* handlers are
  VPC-bound (RDS) — **laptop validation impossible**, so validation moved to the
  CI deploy (heartbeat schedule + plugin connect handshake exercise both
  Lambdas naturally right after deploy).
- The "functors can't take runtime config" worry was **wrong**:
  [ExtensionPoint_Builder.res:67](../../reventless/core/src/components/ExtensionPoint/ExtensionPoint_Builder.res#L67)
  applies `ExtensionPoint_Callback.Make` to an inline module capturing runtime
  values *inside a closure*, and top-level `module X = { let f = runtimeValue }`
  bindings work the same. `PluginExtensionPointEntryPoint` was therefore fully
  convertible — the whole functor assembly the `.mjs` did through compiled-JS
  calls is expressible directly (and `patchSpecId` disappears: a ReScript-level
  `module Id = Reventless.Id.String` in a `SpecWithId` wrapper replaces the
  ESM-export patch-up).
- The two **Pg\* handlers are deferred** (user decision): VPC-bound, one-shot
  deploy-time (`PgMigration`) / scheduled relay (`PgChangeFeedRelay`), high
  blast radius, no incremental validation possible before a deploy.

**What was done (Heartbeat + PluginExtensionPoint):**

- `HeartbeatEntryPoint.res` — full-ReScript entry point (typed `Message.commandJson`
  envelope via `Message.generateMeta`, `commandSchema` reverse-convert,
  `publishJsons(queue, AWS.SQS_FIFO)`); modeled on the deploy-time synthetic
  RedetectPlugin publisher in `Platform.res` (the team's own ReScript port of
  the same logic). Emitted JS is semantically identical to the old shell
  (same `{TAG:"Heartbeat"}` encoding, `"SQS_FIFO"` inlined, eager init).
- `PluginExtensionPointEntryPoint.res` — full-ReScript entry point mirroring
  core's `PluginExtensionPoint_Builder` wiring: `PluginExtensionPoint_Plugin.Make`
  on an inline `EpSpec` module, `ExtensionPoint_Callback.Make` on an inline
  config module, `CommandTopic_Callback.Make` on a `SpecWithId` wrapper.
  Shim seams kept as **typed externals** to `./HandlerFactoryHelpers.mjs`
  (`runEffect`/`setRequestId`/`extract*`/`log.debug`/`scanByTableName`) for
  dispatch-boundary parity with every other deployed entry point.
  `scanByTableName` stays a shim binding deliberately: the ReScript
  `QueryEngine_DynamoDb` module's `make` references `Pulumi.Output`, so
  importing it would leak `@pulumi/*` into the cold-start graph.
- Old `.mjs` shells deleted; `PluginRuntime_Builder` / `PluginExtensionPointRuntime_Builder`
  `entryPointModule` paths point at the compiled `.res.mjs`.
- Verified: root build zero warnings; 296 reventless-aws tests green; a
  transitive import-graph walk over both compiled entry points (92 modules)
  found **no `@pulumi`/`rescript-pulumi`** anywhere.

**Finding — UiFragment mapping divergence (needs decision, NOT changed here):**
core's in-process wiring registers **two** mappings
([PluginExtensionPoint_Builder.res:33-36](../../reventless/core/src/plugin/connect/PluginExtensionPoint_Builder.res#L33-L36):
the Plugin lifecycle mapping **and** `PluginExtensionPoint_UiFragment.Mapping`),
but the deployed Lambda — old `.mjs` and this parity conversion alike — wires
only the lifecycle mapping. If that second mapping is how `RegisterUiFragment`
reaches the admin UiFragmentRegistry slice, AWS deployments may silently drop
plugin UI-fragment registrations (or AWS routes them another way — verify
before "fixing"; adding the mapping also requires the UiFragmentRegistry queue
in `publishToAggregates`, which the builder does not currently wire).

### Deferred-handler conversion (Postgres, 2026-07-27 second pass)

The two Pg\* handlers were converted following the Heartbeat model (relies on the
published layer via `packageDirs=Dict.make()`; the builder's `entryPointModule`
now points at the compiled `.res.mjs`).

1. **`PgMigrationEntryPoint.res`** — reads `HANDLER_CONFIG.pgConnection`, calls
   `ReventlessPostgres.PgSchema.ensureSchema` on `PgRuntime.poolFor(conn)`. The
   `.mjs`'s `opts.makePool` test seam became a labeled `~makePool` arg (default
   `PgRuntime.poolFor`). `PgConnection.connectionConfig` is referenced as a
   **type only** (erased — no runtime import of the Pulumi-carrying `PgConnection`
   module); the raw `JSON.parse` of `HANDLER_CONFIG` structurally satisfies it.
   `PgMigrationEntryPoint_IntegrationTest` was rewritten to call the ReScript
   `runMigration` directly (dropping the two `%raw` dynamic-`import()` blocks).
2. **`PgChangeFeedRelayEntryPoint.res`** — drains each log from its checkpoint
   and relays to EventCollector SQS via `PgChangeFeedRelay_Runtime.relay` /
   `relayClassic` (typed labeled args, replacing the `.mjs`'s fragile positional
   calls). `makeSendBatch` builds the queue ref inline (like Heartbeat) +
   `Util_SQS_Runtime.sendMessage`; per-log log-and-continue error handling via
   `try/catch`. `PgChangeFeedRelay_RuntimeTest` / `_IntegrationTest` call the
   runtime module directly, so the conversion doesn't touch them.

**Latent `@pulumi/pulumi` leak found and fixed.** The relay's runtime graph
reached `@pulumi/pulumi` transitively:
`PgChangeFeedRelay_Runtime → PgChangeFeed → DcbEventLogStorage_Postgres →
@pulumi/pulumi`. Both `PgChangeFeed` and `EventLogChangeFeed` aliased
`module Dcb = DcbEventLogStorage_Postgres` (the deploy-time wrapper) purely for
its pure cursor/decode helpers (`mkBuilder`, `buildReadWhere`, `decodeCursor`,
`selectColumns`, `rowToEvent`) — all of which live in the runtime-pure
`DcbEventLogStorage_Postgres_Ops` that the wrapper only `include`s. Repointing
both aliases at `_Ops` is behavior-preserving (identical bindings) and drops the
Pulumi import from the relay's cold-start graph. This leak pre-existed the
conversion (the old `.mjs` had the same graph) — the relay is a Postgres-backend
Lambda that CI's DynamoDB-backed online-shop-hybrid deploy never exercises, so it
had never surfaced.

**Verification (this pass):** postgres + aws packages and the full root build are
zero-warning green; 297 reventless-aws tests pass; a transitive import-graph walk
over both compiled entry points (34 modules) is **`@pulumi`-free**. Live
validation still pends a real Postgres-backend deploy (VPC-bound — not
laptop-invokable); the migration and relay Lambdas exercise naturally on the
first such `pulumi up` + schedule tick.

### Phase 2 — `_Ops` extraction for Group-1 (separate, later)

Not a full rewrite. For each Group-1 handler that still carries decode/transform
logic inline in the `.mjs`, extract that logic into a typed `*_Ops.res` (as
Aggregate/DCB already do) and leave the `.mjs` as the thin dynamic-import +
SDK-client seam. Prioritise the largest/most-logic-heavy first
(`EventCollectorEntryPoint` 717 LOC, `ReadModelEntryPoint` 179,
`StateViewSliceEntryPoint` 177). Track separately; do not block Phase 1 on it.

### Also fold in (cheap, related)

- The other **4 inline-string handlers** in `.res` files (the remaining
  `handlerCode`/`makeHandlerCode` tier beyond the two we already fixed) are
  candidates to move to `_Ops` on the same rationale — audit and convert where
  the logic is non-trivial. `Platform_UIFragments_Lambda.res` is one.

---

## 5. Risks / open questions

- **Group-1 seam stays untyped** — accepted; conventions endorse a small `.mjs`
  boundary for runtime-specifier `import()`. Do not push `Obj.magic` into `.res`.
- **Archive size** — every `_Ops` conversion bundles `reventless-aws` (+`effect`),
  ~2.1 MB vs. a few KB for inline strings. Same cost the 20 existing EntryPoints
  pay; acceptable for correctness + type-safety. Watch the Lambda 250 MB unzipped
  limit only if many packages get added (not a concern here).
- **`PluginExtensionPointEntryPoint` / `PgChangeFeedRelayEntryPoint` unread** —
  read fully before porting; if either reaches into plugin code or needs raw JS,
  downgrade it to Group 1 (leave as `.mjs`).
- **Version skew is now moot for these Lambdas** (EntryPoints don't serialize the
  SDK) but still exists in the workspace (`rescript-aws-sdk` newer than
  `reventless-aws`); any *remaining* `CallbackFunction`-that-builds-an-SDK-client
  is a latent 502. Audit: `grep -rl "CallbackFunction.make" reventless/aws/src`
  intersect `@aws-sdk`. `RuntimeEnvironment_Lambda.res` has a `CallbackFunction`
  path — verify it is not the same pattern.

---

## 6. Reference — deployed resources (alpha, `eu-west-1`)

- Presign: function `UploadPresignService-da3415a`, role
  `UploadPresignService-d85f38a`, env `UPLOAD_BUCKET=online-shop-uploads-c0f0c03`,
  `SERVED_PREFIX=uploads`.
- Geocoder: function `GeocoderService-db48ef6`, role `GeocoderService-ae811fe`,
  env `PLACE_INDEX_NAME=online-shop-geocoder`.
- Layer: `arn:aws:lambda:eu-west-1:123456789012:layer:reventless-aws-alpha:214`
  (SSM `/reventless/layer-arn/alpha`); `@smithy` in the layer was `4.14.14`.
- Commits (unpushed at time of writing): `39134f2f8` (presign), `6bf9b7c6b`
  (geocoder). Push triggers CI release + layer rebuild + deploy, which replaces
  the two Lambdas with the source-of-truth build.
