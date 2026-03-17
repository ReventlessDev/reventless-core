# Per-Plugin Deployment — Implementation Plan

Based on analysis: `docs/analysis/per-plugin-deployment-strategy.md`

## Goal

Enable independent deployment of each Reventless plugin as a separate Pulumi stack, with a shared platform stack for admin components and the unified AppSync API. Primary target: customer repositories with minimal setup effort.

## Architecture

### Package structure

Each plugin and the platform are split into a **provider-agnostic package** (code, tests, in-memory dev) and an **AWS-specific package** (Pulumi entry point, deployment config):

```
my-app/
├── catalog-spec/          # Spec package (types, interfaces)
├── catalog/               # Plugin code + tests (platform-agnostic)
│   ├── src/
│   ├── tests/
│   ├── package.json       # depends on reventless-infra, reventless-in-memory
│   └── rescript.json
├── catalog-aws/           # AWS deployment entry point
│   ├── src/Main.res       # deployPlugin(~plugin=module(Catalog))
│   ├── package.json       # depends on reventless-aws, catalog — private: true
│   ├── rescript.json
│   ├── Pulumi.yaml
│   ├── Pulumi.alpha.yaml
│   └── Pulumi.main.yaml
├── ordering-spec/
├── ordering/
├── ordering-aws/
├── platform/              # In-memory dev server (all plugins)
│   ├── src/Main.res       # InMemory.Platform.Make(); makePlatform(~plugins=[...])
│   ├── package.json       # depends on reventless-in-memory, catalog, ordering
│   └── rescript.json
├── platform-aws/          # AWS platform deployment
│   ├── src/Main.res       # Platform.Make(); deployPlatform(~version)
│   ├── package.json       # depends on reventless-aws — private: true
│   ├── rescript.json
│   ├── Pulumi.yaml
│   ├── Pulumi.alpha.yaml
│   └── Pulumi.main.yaml
└── deploy-manifest.yaml
```

**Why split?**
- Plugin packages (`catalog/`) never depend on `reventless-aws` — they are platform-agnostic.
- AWS packages (`catalog-aws/`) are proper Lerna workspace members — built, but not published (`private: true`).
- Pulumi files live at the package root — no `deploy/aws/` subdirectory convention needed.
- Adding future providers (`catalog-supabase/`) is just another package.

### Responsibility split

- **Platform stack** (`platform-aws/`) owns all shared resources: the AppSync API (single endpoint), admin components (Plugin aggregate, read model, extension point, cloner), scheduler, and Lambda layer. The platform exports the AppSync API ID so plugin stacks can create DataSources/Resolvers against it.

- **Plugin stacks** (`catalog-aws/`, `ordering-aws/`) deploy their own infrastructure (DynamoDB tables, SQS queues, Lambda functions, S3 buckets) and create AppSync DataSources/Resolvers against the shared API (using the API ID from the platform StackReference). At runtime, plugins register with the platform via the existing **PluginExtensionPoint** — sending a "connect" event that includes their schema fragment. The platform's admin handler receives this event and pushes the updated combined schema to AppSync.

### Schema management — runtime, not deploy-time

Schema stitching is a **runtime** concern, not a deploy-time StackReference read. The existing PluginExtensionPoint already handles plugin connect/disconnect events:

1. **Plugin connects**: Sends a connect event with its schema fragment to the PluginExtensionPoint. The platform's admin handler adds the fragment to the combined schema and calls `AppSync.startSchemaCreation` to update the live API.
2. **Plugin disconnects**: Sends a disconnect event. The platform's admin handler removes that plugin's fragment and pushes the updated schema.

This means:
- No deploy-time StackReference reading for schema stitching
- No second platform deploy needed when plugins change
- Schema updates happen through the existing event-driven mechanism
- The platform doesn't need to know about plugin stacks for schema purposes

### What plugins DO need from the platform (deploy-time)

Plugins still need the **AppSync API ID** (and role ARN) from the platform stack via StackReference to create their own DataSources and Resolvers at deploy time. This is a single value read, not schema stitching.

### Data flow

```
                    Deploy-time                          Runtime
                    ──────────                           ───────

platform-aws stack                               PluginExtensionPoint
┌──────────────────────┐                        ┌──────────────────┐
│  Creates:            │                        │  Receives:       │
│  - AppSync API ──────┼─ exports API ID ──┐    │  - Connect event │
│  - Admin components  │                   │    │    + schema      │
│  - PluginExtPoint    │                   │    │    fragment       │
│  - Scheduler         │                   │    │                  │
└──────────────────────┘                   │    │  Pushes combined │
                                           │    │  schema to       │
Plugin stacks                              │    │  AppSync API     │
┌────────────┐                             │    └──────────────────┘
│catalog-aws │◄── reads API ID ────────────┤              ▲
│  (Lambdas, │                             │              │
│   DynamoDB,│── creates DataSources ──────┤    connect + │
│   SQS)     │   against shared API        │    fragment  │
│            │────────────────────────────────────────────┘
└────────────┘                             │
                                           │
┌────────────┐                             │
│ordering-aws│◄── reads API ID ────────────┘
│  (Lambdas, │
│   DynamoDB,│── creates DataSources
│   SQS)     │   against shared API
│            │──── connect + fragment ──> PluginExtensionPoint
└────────────┘
```

### Deployment order

Single pass: **platform first, then plugins**.

1. **Platform deploys** (`platform-aws`) — creates AppSync API, admin components, PluginExtensionPoint. Exports API ID.
2. **Plugins deploy** (`catalog-aws`, `ordering-aws`, in parallel) — create own infrastructure, create DataSources/Resolvers using platform's API ID. At runtime, send connect event with schema fragment.
3. **Plugin addition** — add a new `-aws` package and deploy. It connects and the schema updates at runtime.
4. **Plugin removal** — destroy the plugin stack. The disconnect event removes the fragment at runtime.
5. **Plugin change** — redeploy the plugin's `-aws` stack. Reconnect updates the schema fragment at runtime.

No second platform deploy is needed. The platform only needs redeployment for its own changes (admin config, scheduler, API resource changes).

## Prerequisites

- Familiarity with the analysis document (architecture, decisions, trade-offs)
- AWS account with Pulumi state backend configured
- GitHub Actions enabled on the target repository

## Steps

### Step 1: Add `Pulumi.export` binding and `Platform.T` type changes

**What**: Add `Pulumi.export` to the ReScript Pulumi bindings. Add `deployPlatform` and `deployPlugin` to the `Platform.T` module type.

**Files**:
- `rescript/rescript-pulumi-pulumi/src/Pulumi.res` — add `export` binding
- `reventless/reventless-infra/src/types/Platform.res` — add `deployPlatform`, `deployPlugin` to `module type T`

- [x] Done

### Step 2: Add ExtensionPoint query to Interstack

**What**: Add an ExtensionPoint query module to `reventless-interop` and wire it into `Interstack` for cross-stack EP resolution.

**Files**:
- `reventless/reventless-interop/src/Query.res` — add `ExtensionPoint` query module
- `reventless/reventless-core/src/util/Interstack.res` + `.resi` — add `DefaultExtensionPointQuery`, `stackDependenciesExtensionPoints`, `mergeExtensionPoints`

- [x] Done

### Step 3: Implement `deployPlugin` — creates infrastructure + DataSources, registers schema at runtime

**What**: `deployPlugin` deploys a single plugin's infrastructure and creates AppSync DataSources/Resolvers against the shared API. Schema registration happens at runtime via the PluginExtensionPoint.

**Details**:
- Plugin reads the platform's AppSync API ID and role ARN via StackReference (`platform:stack` config)
- Plugin creates its own infrastructure (Lambdas, DynamoDB, SQS, S3)
- Plugin creates its own AppSync DataSources/Resolvers pointing to its Lambdas, referencing the shared API by ID
- Plugin creates its own scheduler (closures can't cross stacks)
- At runtime, the plugin's connect handler sends its schema fragment to the PluginExtensionPoint
- Plugin exports `_interopMeta` and extension point data for cross-plugin resolution

**Key requirement**: The plugin needs a way to reconstruct a usable API reference from just the API ID string (read via StackReference). Since all consumers only access `api.id`, a lightweight wrapper or type change is sufficient.

**Files**:
- `reventless/reventless-aws/src/Platform.res` — `deployPlugin` implementation
- `reventless/reventless-aws/src/types/Types.res` — potentially adjust API type to support ID-only references

**Done when**: Plugin creates all infrastructure + DataSources/Resolvers against the shared API. Schema is registered at runtime via PluginExtensionPoint. No AppSync API resource is created by the plugin.

- [x] Done — conditional API creation at module init: if `platform:stack` config is set, constructs phantom API/role from platform's StackReference exports (`apiId`, `apiRoleArn`); otherwise creates a real AppSync API. No Types.res changes needed — `Obj.magic` phantom with only `id`/`arn` fields populated (only fields consumers access).

### Step 4: Implement `deployPlatform` — creates the shared AppSync API and exports its ID

**What**: `deployPlatform` creates the platform stack: admin components, scheduler, and the unified AppSync API. It exports the API ID so plugin stacks can create DataSources/Resolvers against it.

**Details**:
- Creates the single AppSync API endpoint
- Creates admin components (Plugin aggregate, read model, extension point, cloner)
- Exports:
  - `apiId` — the AppSync API ID (for plugin stacks to create DataSources/Resolvers)
  - `apiRoleArn` — the IAM role ARN (for plugin DataSource permissions)
  - `extensionPoints` — admin EP data (for plugin admin connection)
- The admin schema (plugin queries, cloner mutations) is pushed at deploy time
- Plugin schema fragments are pushed at runtime by the PluginExtensionPoint handler when plugins connect

**Files**:
- `reventless/reventless-aws/src/Platform.res` — `deployPlatform` implementation

**Done when**: Platform creates the API, exports its ID, and the admin PluginExtensionPoint handler can receive plugin schema fragments at runtime and update the live API schema.

- [x] Done — pushes admin schema to the main `appSyncApi` (no separate core-api), exports `apiId` and `apiRoleArn` as stack outputs, exports admin extension points.

### Step 5: Implement runtime schema stitching in the PluginExtensionPoint handler

**What**: When a plugin connects (sends connect event to PluginExtensionPoint), the platform handler should include the plugin's schema fragment in the combined schema and push it to AppSync.

**Details**:
- The connect event payload already includes plugin metadata — add `apiSchemaFragment` to it
- The Platform Admin's event handler receives the connect event and calls `AppSync_Adapter.updateSchema` with the admin base fragment + all connected plugin fragments
- On disconnect, the handler removes that plugin's fragment and pushes the updated schema
- The `updateSchema` call uses the platform's own AppSync API reference (available locally, not via StackReference)

**Files**:
- `reventless/reventless-aws/src/core/Plugin_ExtensionPoint_Builder.res` — added `MakeWithConfig` functor accepting `updateApiSchema`
- `reventless/reventless-aws/src/Platform.res` — `deployPlatform` creates PluginExtensionPoint with `updateApiSchema` implementation and passes it to `Admin.construct`
- No core changes needed: `pluginDefinition.apiSchemaFragment` was already included in connect events; `PluginExtensionPoint_Plugin.res` already called `updateApiSchema` on DoConnectPlugin/DoDisconnectPlugin

**Implementation**:
- `deployPlatform` creates a `PluginExtensionPoint` via `Plugin_ExtensionPoint_Builder.MakeWithConfig` with a closure that:
  1. Captures `appSyncApiId` (Pulumi Output) — serialized into the Lambda by Pulumi's CallbackFunction; at runtime `Output.get` returns the resolved string
  2. Queries the Plugin read model for all `status: Connected` plugins
  3. Extracts `apiSchemaFragment` from each plugin's state
  4. Stitches admin base fragment + all plugin fragments via `GraphQL_Stitcher.stitch`
  5. Pushes the combined schema to AppSync via `startSchemaCreation`
- The PluginExtensionPoint is passed to `Admin.construct(~extensionPoints=[module(PluginExtensionPoint)])` so the platform stack includes the full PluginExtensionPoint infrastructure (SQS command topic, Lambda handler, SNS event topic)

**Done when**: Adding or removing a plugin dynamically updates the AppSync schema at runtime without redeploying the platform.

- [x] Done

### Step 6: Create `-aws` packages for `online-shop-hybrid` example

**What**: Replace the `deploy/aws/` subdirectories with proper `-aws` Lerna packages.

**Details**:
- Create `examples/online-shop-hybrid/platform-aws/` — `src/Main.res` calls `deployPlatform`, with `Pulumi.yaml` + `Pulumi.<env>.yaml` at package root
- Create `examples/online-shop-hybrid/catalog-aws/` — `src/Main.res` calls `deployPlugin` with Catalog
- Create `examples/online-shop-hybrid/ordering-aws/` — `src/Main.res` calls `deployPlugin` with Ordering
- Remove old `*/deploy/aws/` directories
- Each `-aws` package: `package.json` with `"private": true`, `rescript.json` with `reventless-aws` + plugin dependency
- Register `-aws` packages in Lerna workspaces
- Update `deploy-manifest.yaml` paths to point to `-aws` package roots
- Verify `npm run dev` in `platform/` still works unchanged (in-memory dev unaffected)

**Files**:
- `examples/online-shop-hybrid/platform-aws/` (new package)
- `examples/online-shop-hybrid/catalog-aws/` (new package)
- `examples/online-shop-hybrid/ordering-aws/` (new package)
- `examples/online-shop-hybrid/deploy-manifest.yaml` — update paths
- Remove `examples/online-shop-hybrid/*/deploy/aws/`

- [x] Done — created `platform-aws/`, `catalog-aws/`, `ordering-aws/` packages; removed old `*/deploy/aws/` directories; updated `deploy-manifest.yaml` paths.

### Step 7: Update GitHub Actions workflow

**What**: Simplify deployment ordering — platform first, then plugins. No second pass needed. Update paths to `-aws` packages.

**Details**:
- Platform deploys first (creates API, admin EP)
- Plugins deploy in parallel after platform completes
- No platform redeploy after plugin changes (schema updates happen at runtime)
- Platform only redeploys when its own code changes
- Manifest paths point to `-aws` package roots (e.g., `catalog-aws/` not `catalog/deploy/aws/`)

**Files**:
- `.github/workflows/deploy-reventless-aws.yml`

- [x] Done — no workflow changes needed; the reusable workflow reads paths from deploy-manifest.yaml which was updated in Step 6.

### Step 8: Update templates, guide, and analysis docs

**What**: Update all documentation to reflect the `-aws` package split and runtime schema registration architecture.

**Files**:
- `docs/templates/deploy-aws/` — update templates to reflect package structure
- `docs/guides/deployment-guide.md` — update architecture, package structure, examples
- `docs/analysis/per-plugin-deployment-strategy.md` — update to reflect final architecture

- [x] Done — Pulumi.yaml template `main` updated to `src/Main.res.mjs`; deployment-guide.md already reflected `-aws` package structure; analysis doc annotated with note pointing to final architecture.

### Step 9: Add caller workflow to deploy `online-shop-hybrid` example

**What**: Add a GitHub Actions workflow that calls the reusable `deploy-reventless-aws.yml` workflow to deploy the `online-shop-hybrid` example on push to `alpha`/`main`.

**Details**:
- Create `.github/workflows/deploy-online-shop-hybrid.yml` that invokes the reusable workflow
- `manifest` input points to `examples/online-shop-hybrid/deploy-manifest.yaml`
- Manifest paths (`platform-aws`, `catalog-aws`, `ordering-aws`) are relative to the manifest's directory — the reusable workflow resolves them via `--cwd` using the manifest's parent as the working directory
- The reusable workflow's change detection uses `git diff` paths (repo-root-relative) — the `detect-changes` job needs to prefix manifest paths with the manifest's parent directory for accurate path matching
- Required secrets: `PULUMI_ACCESS_TOKEN`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `NPM_TOKEN`
- Pulumi stacks must be initialized in the Pulumi backend before the first deploy (`pulumi stack init alpha` etc.)

**Files**:
- `.github/workflows/deploy-online-shop-hybrid.yml` (new)
- `.github/workflows/deploy-reventless-aws.yml` — may need adjustment so that change detection and `--cwd` correctly resolve manifest-relative paths when the manifest is not at the repo root

**Done when**: Pushing to `alpha` triggers platform + plugin deployments for the online-shop-hybrid example.

- [x] Done — created `.github/workflows/deploy-online-shop-hybrid.yml` caller workflow; fixed reusable workflow path resolution to prepend manifest parent directory for repo-root-relative paths.

### Step 10: Build `create-reventless-platform` scaffolding package

**What**: An npm package that scaffolds a complete Reventless project with deployment configuration.

**Done when**: `npx create-reventless-platform` generates a working project that can be deployed immediately.

- [ ] Deferred — template files provide manual setup path for early adopters

## Implementation Order

1. `deployPlatform` rework (Step 4) — export API ID
2. `deployPlugin` rework (Step 3) — reference shared API, create DataSources/Resolvers
3. Runtime schema stitching (Step 5) — PluginExtensionPoint handler
4. `-aws` packages for example (Step 6) — validate end-to-end
5. Workflow + docs (Steps 7-8)
6. Caller workflow for online-shop-hybrid (Step 9) — end-to-end deployment validation

Steps 4 and 3 are sequential (plugin needs the API ID export from platform). Step 5 can be developed in parallel with Steps 3-4. Steps 7-8 can be done after Step 6. Step 9 requires Steps 6-8 to be complete.
