# Per-Plugin AWS Deployment Guide

This guide covers deploying a Reventless application to AWS using independent per-plugin Pulumi stacks, automated by GitHub Actions.

## 1. Overview

A Reventless application is deployed as **one Pulumi stack per plugin** plus a **platform stack**:

- **Platform stack** (`platform-aws`) -- deploys the shared AppSync API (single unified endpoint), admin components (Plugin aggregate, read model, extension point), scheduler, and Lambda Layer. Exports the API ID so plugins can create DataSources/Resolvers against it.
- **Plugin stacks** (`catalog-aws`, `ordering-aws`) -- each plugin deploys its own infrastructure (DynamoDB, SQS, Lambda, S3) and creates AppSync DataSources/Resolvers against the shared API. At runtime, plugins register their GraphQL schema fragment with the platform via the PluginExtensionPoint.

### Package split: agnostic + AWS

Each plugin and the platform are split into two packages:

| Package | Purpose | Depends on |
|---|---|---|
| `catalog/` | Plugin code, tests, local dev | `reventless-infra`, `reventless-local` |
| `catalog-aws/` | AWS deployment entry point | `reventless-aws`, `catalog` |
| `platform/` | Local dev server (all plugins) | `reventless-local`, all plugins |
| `platform-aws/` | AWS platform deployment | `reventless-aws` |

Plugin packages never depend on `reventless-aws`. The `-aws` packages are private (`"private": true` in `package.json`) — they are entry points, not published libraries.

### How schema management works

Schema stitching is a **runtime** concern, not deploy-time:

1. When a plugin **connects**, it sends a connect event including its schema fragment to the PluginExtensionPoint. The platform's admin handler adds the fragment to the combined schema and pushes it to AppSync.
2. When a plugin **disconnects**, the platform removes that fragment and pushes the updated schema.

No platform redeployment is needed when plugins change.

### Benefits

- **Independent deployments** -- changing a single plugin only redeploys that plugin's `-aws` stack.
- **Clean dependency graph** -- plugin code never touches AWS. AWS coupling is isolated in `-aws` packages.
- **Dynamic schema** -- plugins register/deregister their schema fragments at runtime via the PluginExtensionPoint.
- **Reduced blast radius** -- a failed deployment affects only one plugin's stack.
- **Parallel deploys** -- independent plugins deploy concurrently.
- **Multiple providers** -- adding `catalog-supabase/` later is just another package.

## 2. Prerequisites

| Requirement | Details |
|---|---|
| AWS account | With IAM credentials that have permissions to create DynamoDB, Lambda, SQS, SNS, S3, AppSync, and IAM resources |
| Pulumi CLI | Installed locally (`brew install pulumi` or `curl -fsSL https://get.pulumi.com \| sh`) |
| Pulumi state backend | Pulumi Cloud account (free tier) or self-managed S3 backend |
| Node.js v22+ | See `.node-version` in the project root |
| npm access to `@reventlessdev/*` | GitHub Package Registry token with `read:packages` scope |
| ReScript compiler | Installed via npm (included in `@reventlessdev/reventless-aws` dependencies) |

## 3. Architecture

### Stack structure

```
                      +---------------------------+
                      |   platform-aws            |
                      |   (admin, scheduler, API) |
                      |   exports: API ID,        |
                      |     admin EP, role ARN    |
                      +---------------------------+
                             |            |
              StackReference |            | StackReference
              (API ID, EPs)  |            | (API ID, EPs)
                             v            v
                +----------------+  +----------------+
                | catalog-aws    |  | ordering-aws   |
                | (plugin infra, |  | (plugin infra, |
                |  DataSources,  |  |  DataSources,  |
                |  Resolvers)    |  |  Resolvers)    |
                +----------------+  +----------------+
                        |                    |
                        |  runtime connect   |  runtime connect
                        |  + schema fragment |  + schema fragment
                        v                    v
                  PluginExtensionPoint (platform runtime)
                  --> pushes combined schema to AppSync
```

### Data flow

**Deploy-time:**
- Platform creates the AppSync API and exports its ID + role ARN as stack outputs.
- Each plugin reads the API ID via StackReference and creates its own DataSources/Resolvers pointing to its Lambda functions.
- Plugins also read admin extension points from the platform for the admin connection path.

**Runtime:**
- Each plugin sends a "connect" event to the PluginExtensionPoint, including its schema fragment.
- The platform's admin handler stitches all connected plugin fragments into a combined schema and pushes it to AppSync.
- When a plugin disconnects, its fragment is removed and the schema is updated.

**Cross-plugin:**
- Plugins that consume another plugin's extension point read that plugin's exported EP data via StackReference (`interstack:dependencies`).

### Deployment order

Single pass: **platform first, then plugins**.

1. Platform deploys -- creates API, admin components, PluginExtensionPoint. Exports API ID.
2. Plugins deploy in parallel -- create infrastructure, create DataSources/Resolvers using the platform's API ID. At runtime, connect and register schema.

No second platform deploy is needed when plugins change.

## 4. Step-by-step Setup

### 4a. Create the package structure

Each plugin gets an `-aws` package alongside its agnostic package. The platform gets `platform/` (local) and `platform-aws/` (AWS):

```
my-app/
├── catalog-spec/
├── catalog/
│   ├── src/Plugin.res
│   ├── tests/
│   ├── package.json
│   └── rescript.json
├── catalog-aws/
│   ├── src/Main.res
│   ├── package.json
│   ├── rescript.json
│   ├── Pulumi.yaml
│   ├── Pulumi.alpha.yaml
│   └── Pulumi.main.yaml
├── ordering-spec/
├── ordering/
├── ordering-aws/
│   ├── src/Main.res
│   ├── ...
├── platform/
│   ├── src/Main.res                  # Local dev server
│   ├── package.json
│   └── rescript.json
├── platform-aws/
│   ├── src/Main.res
│   ├── package.json
│   ├── rescript.json
│   ├── Pulumi.yaml
│   ├── Pulumi.alpha.yaml
│   └── Pulumi.main.yaml
├── deploy-manifest.yaml
├── package.json
└── .github/workflows/deploy-aws.yml
```

Register the `-aws` packages as Lerna workspaces in the root `package.json` and `lerna.json`.

### 4b. Add `Main.res` entry points

Templates are available in `docs/templates/deploy-aws/`.

**`platform-aws/src/Main.res`** -- deploys admin components, scheduler, and the shared API:

```rescript
module Platform = ReventlessAws.Platform.Make()

let default = Platform.deployPlatform(~version=Reventless.PackageVersion.fromCaller())
```

**`catalog-aws/src/Main.res`** -- deploys a single plugin's infrastructure:

> Note: This file is **auto-generated** by `generate-plugin --aws`. Do not edit it manually — run `pnpm run generate` to regenerate.

```rescript
// AUTO-GENERATED — do not edit. Run `pnpm run generate` to update.
// Catalog plugin — AWS deployment.

module Platform = ReventlessAws.Platform.Make()
module Catalog = Plugin.Make(Platform)

let default = Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~plugin=module(Catalog),
)
```

Key points:
- `Platform.Make()` configures the infrastructure builders. In per-plugin mode, it reads the platform's API ID from the `platform:stack` StackReference.
- Plugins create their own DataSources/Resolvers against the shared API. The schema fragment is registered at runtime via the PluginExtensionPoint.

**`platform/src/Main.res`** -- local dev server (unchanged):

```rescript
module Platform = ReventlessLocal.Platform.Make()

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
)
```

### 4c. Add `package.json` for `-aws` packages

Each `-aws` package is a private Lerna workspace member:

```json
{
  "name": "@myorg/catalog-aws",
  "version": "0.0.0",
  "private": true,
  "dependencies": {
    "@reventlessdev/reventless-aws": "^3.0.0",
    "@myorg/catalog": "*"
  }
}
```

### 4d. Add `rescript.json` for `-aws` packages

```json
{
  "name": "catalog-aws",
  "sources": [{ "dir": "src", "subdirs": false }],
  "dependencies": [
    "sury",
    "@reventlessdev/reventless-aws",
    "@reventlessdev/reventless-infra",
    "@reventlessdev/reventless-spec",
    "@reventlessdev/rescript-pulumi-pulumi",
    "@myorg/catalog"
  ],
  "ppx-flags": ["sury-ppx/bin"],
  "package-specs": { "module": "esmodule", "in-source": true },
  "suffix": ".res.mjs"
}
```

### 4e. Add `Pulumi.yaml` per stack

Each `-aws` package root gets a `Pulumi.yaml` project definition:

```yaml
name: my-app-catalog
runtime: nodejs
main: src/Main.res.mjs
description: My App — Catalog plugin stack
```

- `name` must be globally unique within your Pulumi organization.
- `main` points to the compiled ReScript output.

### 4f. Add `Pulumi.<env>.yaml` per environment

Create one file per environment the stack should deploy to.

**Platform** (`platform-aws/Pulumi.alpha.yaml`):

```yaml
config:
  aws:region: eu-west-1
```

**Independent plugin** (`catalog-aws/Pulumi.alpha.yaml`):

```yaml
config:
  aws:region: eu-west-1
  platform:stack: org/my-app-platform/alpha
```

**Plugin with cross-plugin dependency** (`ordering-aws/Pulumi.alpha.yaml`):

```yaml
config:
  aws:region: eu-west-1
  platform:stack: org/my-app-platform/alpha
  interstack:
    dependencies:
      - org/my-app-catalog/alpha
```

The branch name determines the environment: push to `alpha` uses `Pulumi.alpha.yaml`, push to `main` uses `Pulumi.main.yaml`. If no matching file exists, no deployment occurs.

#### Per-instance overrides (env var, `Pulumi.local.yaml`)

Some values vary per deploy target (existing AWS resource IDs to reuse, personal Cognito UserPools, etc.) and should not live in the checked-in `Pulumi.<stack>.yaml`. `Util_LocalConfig` (`reventless/aws/src/util/Util_LocalConfig.res`) reads two layered sources at deploy time; the first match wins, otherwise lookup falls through to Pulumi stack config (then auto-provision).

| Precedence | Source | Typical use |
|---|---|---|
| 1 (highest) | Env var `REVENTLESS_<KEY_IN_SCREAMING_SNAKE>` | CI deploys (repo / environment secrets) |
| 2 | `Pulumi.local.yaml` sidecar (gitignored) | Dev-local override |
| 3 | `platform:<key>` in `Pulumi.<stack>.yaml` (checked in) | Shared default |

Currently consumed by:

| Config key | Env var | Used by | Behavior when unset |
|---|---|---|---|
| `identityProviderId` | `REVENTLESS_IDENTITY_PROVIDER_ID` | `Platform_Stack.resolveCognitoUserPool` | Auto-provisions a fresh UserPool **and** its active-role store |
| `hostUiBaseDomain` | `REVENTLESS_HOST_UI_BASE_DOMAIN` | `Platform.deployPlatform` (host UI custom domain) | Keeps `*.cloudfront.net` default URL |
| `hostUiHostedZoneId` | `REVENTLESS_HOST_UI_HOSTED_ZONE_ID` | same | Keeps `*.cloudfront.net` default URL |
| `hostUiBaseName` | `REVENTLESS_HOST_UI_BASE_NAME` | same | Defaults to `Pulumi.getProjectName()` |
| `hostUiProdStacks` | `REVENTLESS_HOST_UI_PROD_STACKS` (CSV) | same | Defaults to `["prod", "main"]` |

Any future deploy-time helper reading via `Util_LocalConfig.get("…")` automatically participates in the same precedence ladder.

:::caution `cognitoUserPoolId` is the deprecated spelling
`identityProviderId` was `cognitoUserPoolId` (`REVENTLESS_COGNITO_USER_POOL_ID`).
The old key is still read at every level of the ladder and logs a warning.

Do not drop it until the new one is confirmed in place everywhere, because **an
unset provider id is not an error — it is auto mode, and auto mode creates a new
user pool.** A caller left on the old spelling after it stops being read deploys
green, mints a fresh pool, and orphans every existing account.
:::

#### Bringing your own identity provider

Setting `identityProviderId` means the pool is yours, not the framework's — and
so is the **active-role store**, the table the pool's pre-token-generation trigger
reads to narrow a caller's groups to the role they chose. The two are provisioned
together, outside every stack, because a Cognito pool has exactly **one** trigger
slot: two platform stacks on one pool each deploying their own store would leave
the winning trigger reading rows the other platform's resolver never writes, and
every role switch would report success and do nothing.

The store's name is **derived, not configured** —
`ReventlessActiveRoleStore-<identityProviderId>` — so every stack on the provider
resolves the same table and no two can disagree. Provision both with:

```bash
# create a pool and its store
pnpm --filter @reventlessdev/reventless-aws run provision:identity -- --name MyIdentity

# or add the store to a pool you already have
pnpm --filter @reventlessdev/reventless-aws run provision:identity -- --provider-id eu-west-1_AbCdEfGhI
```

Re-running is safe — existing resources are adopted, never recreated. The script
deliberately does **not** attach the trigger; the deploy does that, and refuses if
the pool's slot is held by a trigger that is not one of ours.

A stack given an `identityProviderId` whose pool or store does not exist **fails
the deploy**. Both exist or neither does.

Each platform on a shared provider keeps its **own** active role: rows are keyed
by `(sub, clientId)`, and each stack declares its own app client. Narrowing to a
role in one platform leaves the others as they were.

**Host UI custom domain.** Both `hostUiBaseDomain` and `hostUiHostedZoneId` must be set together — if either is missing the framework keeps the default `*.cloudfront.net` URL. When both are set, the framework provisions an ACM cert (us-east-1) + Route53 alias and serves the shell at `${baseName}-${stack}.${baseDomain}` (or `${baseName}.${baseDomain}` when `stack ∈ hostUiProdStacks`). See [`ui-fragments-deployment.md`](./ui-fragments-deployment.md) → "Conditional: custom domain" for the full provisioning detail and [`docs/analysis/host-ui-custom-domain.md`](https://github.com/ReventlessDev/reventless-core/blob/alpha/docs/analysis/host-ui-custom-domain.md) for the design rationale and multi-tenancy notes.

:::caution Do not commit `hostUiBaseDomain`
Set it per deployment — an environment variable or an untracked local config —
never in a checked-in `Pulumi.<stack>.yaml`. A committed value points every fork
of that config at a Route53 zone its owner does not control: the certificate
request simply fails, having tried to provision in somebody else's zone.
:::

**Env var (CI deploys):**

camelCase config key → `REVENTLESS_<SCREAMING_SNAKE>`. Example for `identityProviderId`:

```yaml
# .github/workflows/deploy-online-shop-hybrid.yml
jobs:
  deploy:
    uses: ./.github/workflows/deploy-reventless-aws.yml
    secrets:
      …
    # In deploy-reventless-aws.yml, surface the env var to the pulumi step:
    # env:
    #   REVENTLESS_IDENTITY_PROVIDER_ID: ${{ secrets.IDENTITY_PROVIDER_ID }}
```

An empty value is treated as "not set" so a stray empty export does not mask the sidecar.

**Sidecar (dev-local):**

```yaml
# platform-aws/Pulumi.local.yaml — gitignored, read from process.cwd()
identityProviderId: eu-west-1_AbCdEfGhI
```

Notes:
- **Bare keys, no namespace prefix.** The same value in `Pulumi.<stack>.yaml` would be written `platform:identityProviderId: …`; the sidecar drops the `platform:` prefix because lookup happens after the namespace is bound.
- Format: minimal `key: value` lines. Quotes optional, `#` introduces comments, blank lines ignored — not a full YAML parser.
- Gitignored at the repo root via `**/Pulumi.local.yaml` — verify with `git check-ignore -v platform-aws/Pulumi.local.yaml`.

#### Plugin UI bundle URL (optional)

Plugins with aggregates or read models accept an optional UI bundle URL — the location of the Module-Federation remote that exposes the plugin's React components for the platform shell. The generated AWS `Plugin.res` reads `<PLUGIN>_UI_BUNDLE_URL` from `process.env` (PascalCase plugin name → SCREAMING_SNAKE_CASE: `Catalog` → `CATALOG_UI_BUNDLE_URL`). Unset → no UI fragments are registered for that plugin.

Set it on the deployed Lambda by adding the env var to the Pulumi stack config and threading it through to the plugin's deploy step. The same env-var name is consumed by the local dev platform, so a single setting works for both deploy paths. See `platform-and-plugin-guide.md` → AutoUI for the runtime mechanics.

### 4g. Create `deploy-manifest.yaml` at the project root

This manifest tells the GitHub Actions workflow which stacks exist and their deployment order:

```yaml
platform:
  path: platform-aws
  name: my-app-platform

plugins:
  - name: catalog
    path: catalog-aws
    depends-on: []

  - name: ordering
    path: ordering-aws
    depends-on:
      - catalog
```

- `path` points to the `-aws` package root (relative to repo root).
- `name` matches the Pulumi project name (without the org prefix).
- `depends-on` declares deployment ordering.

### 4h. Add the GitHub Actions workflow

Create `.github/workflows/deploy-aws.yml`:

```yaml
name: Deploy to AWS

on:
  push:
    branches: [main, alpha, beta]
  pull_request:
    branches: [main]

jobs:
  deploy:
    uses: ReventlessDev/reventless-core/.github/workflows/deploy-reventless-aws.yml@main
    with:
      manifest: deploy-manifest.yaml
      node-version: "22"
    secrets:
      PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

The reusable workflow handles change detection, environment selection, deployment ordering, and secret resolution automatically.

## 5. Multi-Repository Setup

The same architecture works when plugins live in separate repositories. Each plugin repo contains its agnostic package and its `-aws` package. The platform lives in its own repo.

### Repository structure

```
repo: my-org/platform
├── platform/                  # Local dev server (depends on all plugins)
├── platform-aws/              # AWS platform deployment
├── deploy-manifest.yaml       # platform only
└── .github/workflows/deploy-aws.yml

repo: my-org/catalog
├── catalog-spec/
├── catalog/
├── catalog-aws/
├── deploy-manifest.yaml       # catalog plugin only
└── .github/workflows/deploy-aws.yml

repo: my-org/ordering
├── ordering-spec/
├── ordering/
├── ordering-aws/
├── deploy-manifest.yaml       # ordering plugin only
└── .github/workflows/deploy-aws.yml
```

### What changes from monorepo

**One manifest per repo.** Each repo has its own `deploy-manifest.yaml` listing only the stacks in that repo:

```yaml
# repo: my-org/catalog — deploy-manifest.yaml
plugins:
  - name: catalog
    path: catalog-aws
    depends-on: []
```

```yaml
# repo: my-org/platform — deploy-manifest.yaml
platform:
  path: platform-aws
  name: my-app-platform
```

**Published package dependencies.** The `-aws` package depends on the published plugin package, not a workspace link:

```json
{
  "name": "@myorg/catalog-aws",
  "private": true,
  "dependencies": {
    "@reventlessdev/reventless-aws": "^3.0.0",
    "@myorg/catalog": "^1.2.0"
  }
}
```

**Each repo calls the reusable workflow independently.** Push to the catalog repo triggers catalog's workflow. Push to the platform repo triggers the platform's workflow. They are independent CI pipelines.

**Cross-plugin StackReferences work across repos.** `interstack:dependencies` and `platform:stack` are Pulumi stack names — they reference stacks by name, not by repo. Ordering in repo B can reference catalog in repo A's stack:

```yaml
# repo: my-org/ordering — ordering-aws/Pulumi.alpha.yaml
config:
  aws:region: eu-west-1
  platform:stack: myorg/my-app-platform/alpha
  interstack:
    dependencies:
      - myorg/my-app-catalog/alpha
```

### Platform repo and local development

The platform repo contains `platform/` for the local dev server. It depends on all plugin packages (published versions). For local development with unpublished plugin changes, use `npm link` or workspace overrides to point to local checkouts.

### Deployment coordination

| Scenario | What to do |
|---|---|
| Plugin code change | Push to plugin repo. CI deploys the `-aws` stack. Schema updates at runtime. |
| New plugin | Create new repo with plugin + `-aws` packages. Deploy. Platform is untouched. |
| Remove plugin | Destroy the plugin stack. Remove the repo. Schema updates at runtime. |
| Cross-plugin spec change | Publish the spec package. Update dependent plugin repos. Deploy each. |
| Framework upgrade | Update `@reventlessdev/*` versions in each repo. Deploy platform first, then plugins. |

### What stays identical

- Pulumi stack structure (platform + per-plugin stacks)
- `platform:stack` and `interstack:dependencies` config
- Runtime schema registration via PluginExtensionPoint
- The reusable workflow (called from each repo)
- Deployment order (platform first, then plugins)
- Secret management (per-repo GitHub secrets with environment overrides)

## 6. Configuration

### `platform:stack` -- platform stack reference

Every plugin stack must reference the platform stack so it can read the shared API ID and admin extension points:

```yaml
config:
  platform:stack: org/my-app-platform/alpha
```

The format is `<pulumi-org>/<project-name>/<stack-name>`. The stack name matches the branch/environment name.

### `interstack:dependencies` -- cross-plugin StackReferences

When a plugin consumes another plugin's extension point (e.g., ordering subscribes to catalog events), it needs a StackReference to that plugin:

```yaml
config:
  interstack:
    dependencies:
      - org/my-app-catalog/alpha
```

Multiple dependencies are supported as a YAML list. The ordering plugin reads the catalog plugin's exported `_interopMeta` to resolve extension point bindings at deploy time.

### Environment-specific configuration

Each environment gets its own `Pulumi.<env>.yaml`. Common differences between environments:

| Setting | Alpha | Main (Production) |
|---|---|---|
| `aws:region` | `eu-west-1` | `eu-west-1` |
| `platform:stack` | `org/my-app-platform/alpha` | `org/my-app-platform/main` |
| `interstack:dependencies` | `org/.../alpha` | `org/.../main` |

Add custom config keys per environment for Lambda memory, DynamoDB capacity, or feature flags:

```yaml
config:
  aws:region: eu-west-1
  platform:stack: org/my-app-platform/main
  my-app-catalog:lambdaMemory: 1024
  my-app-catalog:dynamoDbBillingMode: PROVISIONED
```

### Branch name = Pulumi stack name

The git branch name is used directly as the Pulumi stack name. Deployment only happens if a `Pulumi.<branch>.yaml` file exists in the `-aws` package root.

- Push to `alpha` -- looks for `Pulumi.alpha.yaml` -- deploys if found.
- Push to `main` -- looks for `Pulumi.main.yaml` -- deploys if found.
- Push to `feature-xyz` -- no `Pulumi.feature-xyz.yaml` -- skipped.

### Adding or removing environments

| Action | What to do | Workflow change needed? |
|---|---|---|
| Add `test` environment | Create `test` branch + `Pulumi.test.yaml` in every `-aws` package | No |
| Add temporary `demo` environment | Create `demo` branch + `Pulumi.demo.yaml` in relevant `-aws` packages | No |
| Remove an environment | Delete its `Pulumi.<env>.yaml` files | No |
| Disable one plugin on one branch | Rename `Pulumi.<branch>.yaml` to `Pulumi.<branch>.yaml.disabled` | No |

### Stack naming

Each plugin and the platform get their own Pulumi stack per environment:

```
org/my-app-platform/alpha      org/my-app-platform/main
org/my-app-catalog/alpha       org/my-app-catalog/main
org/my-app-ordering/alpha      org/my-app-ordering/main
```

## 7. Deployment Scenarios

### First deployment

1. Ensure all `Pulumi.yaml` and `Pulumi.<env>.yaml` files are committed.
2. Deploy the platform stack first:
   ```bash
   cd platform-aws
   pulumi up --stack alpha
   ```
3. Deploy plugins (can run in parallel if independent):
   ```bash
   cd catalog-aws
   pulumi up --stack alpha
   ```
4. Deploy dependent plugins after their dependencies:
   ```bash
   cd ordering-aws
   pulumi up --stack alpha
   ```

Or push to the `alpha` branch and let GitHub Actions handle the ordering automatically.

### Adding a new plugin

1. Create the plugin package (`shipping/`) and its AWS package (`shipping-aws/`).
2. Add `src/Main.res`, `package.json`, `rescript.json`, `Pulumi.yaml`, and `Pulumi.<env>.yaml` to `shipping-aws/`.
3. Register `shipping-aws/` in the Lerna workspaces.
4. Add the plugin entry to `deploy-manifest.yaml`:
   ```yaml
   - name: shipping
     path: shipping-aws
     depends-on: []
   ```
5. If the plugin consumes another plugin's extension point, add `depends-on` and `interstack:dependencies`.
6. Commit and push. The workflow deploys the plugin. At runtime, the plugin connects to the PluginExtensionPoint and its schema fragment is added to the unified API.

No platform redeployment is needed.

### Updating a plugin (independent redeploy)

Change the plugin's source code and push. Only that plugin's `-aws` stack redeploys. At runtime, the reconnect updates the schema fragment if it changed. No platform or other plugin stacks are touched.

### Removing a plugin

1. Destroy the plugin stack: `pulumi destroy --stack alpha` from the `-aws` package.
2. Remove the `-aws` package and the plugin entry from `deploy-manifest.yaml`.

At runtime, the disconnect event removes the plugin's schema fragment from the unified API. No platform redeployment needed.

### Cross-plugin extension wiring

When plugin B subscribes to plugin A's extension point:

1. Plugin A exports its extension points as stack outputs (handled automatically by `deployPlugin`'s `_interopMeta` export).
2. Plugin B declares a dependency on plugin A in `deploy-manifest.yaml` (`depends-on: [pluginA]`).
3. Plugin B's `Pulumi.<env>.yaml` includes a StackReference to plugin A:
   ```yaml
   interstack:
     dependencies:
       - org/my-app-pluginA/alpha
   ```
4. At deploy time, plugin B reads plugin A's outputs via StackReference and wires the extension binding.

## 8. API Functions

### `Platform.deployPlatform(~version)`

Called in `platform-aws/src/Main.res`. Creates:
- **AppSync API** -- the single unified GraphQL endpoint for the entire application.
- **Scheduler** -- Pulumi component for scheduling recurring tasks.
- **Admin components** -- Plugin aggregate, read model, extension point (via `Platform_Admin.construct`).
- **Stack outputs** -- exports API ID, role ARN, and admin extension points for plugin stacks to consume.

Returns `dict<Pulumi.Output.t<JSON.t>>` -- the Pulumi stack outputs dict. Assign as the ESM default export: `let default = Platform.deployPlatform(...)`.

The admin schema (plugin queries, cloner mutations) is pushed at deploy time. Plugin schema fragments are added at runtime when plugins connect.

### `Platform.deployPlugin(~version, ~plugin)`

Called in each plugin's `-aws` package (e.g., `catalog-aws/src/Main.res`). Creates:
- **Scheduler** -- each plugin stack creates its own scheduler instance (closures cannot cross Pulumi stacks).
- **Plugin infrastructure** -- all DynamoDB tables, SQS queues, Lambda functions, and S3 buckets for the plugin's aggregates, read models, tasks, and DCB slices.
- **AppSync DataSources/Resolvers** -- created against the shared API using the API ID from the platform StackReference.
- **Stack outputs** -- exports `_interopMeta` (extension points, event topics) for cross-stack consumption by dependent plugins.

Returns `dict<Pulumi.Output.t<JSON.t>>` -- the Pulumi stack outputs dict. Assign as the ESM default export: `let default = Platform.deployPlugin(...)`. The plugin name is auto-registered by `Plugin_Builder.make` -- no manual `registerDcbConfig` call is needed.

At runtime, the plugin connects to the PluginExtensionPoint with its schema fragment. The platform updates the combined schema.

### `Platform.makePlatform(~version, ~plugins)`

Monolithic deployment mode (still supported). Deploys the platform and all plugins in a single Pulumi stack. Used by the `platform/` package for local development:

```rescript
Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[
    module(Catalog),
    module(Ordering),
  ],
)
```

This creates one stack with all resources. To migrate to per-plugin deployment, create the `-aws` packages as described in this guide.

## 9. Secret Management

### Required GitHub secrets (platform-wide defaults)

Go to your GitHub repo Settings, then Secrets and variables, then Actions, then Repository secrets:

| Name | Value | Purpose |
|---|---|---|
| `PULUMI_ACCESS_TOKEN` | Your Pulumi access token | Authenticates Pulumi CLI (default for all stacks) |
| `AWS_ACCESS_KEY_ID` | IAM access key | AWS authentication for resource creation |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key | AWS authentication for resource creation |
| `NPM_TOKEN` | GitHub Package Registry token | Install `@reventlessdev/*` packages |

These are the defaults used by the platform and all plugins unless overridden.

### Per-plugin secret overrides (optional)

To use a different Pulumi access token or AWS credentials for a specific plugin:

1. Go to Settings, then Environments, then New environment.
2. Name it `deploy-<plugin>` (e.g., `deploy-catalog`).
3. Add a `PULUMI_ACCESS_TOKEN` secret (and/or `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) to that environment. These override the repository-level defaults for that plugin's deployment job.

The same mechanism works for the platform stack via the `deploy-platform` environment.

**Resolution order**: environment secret (per-plugin or per-platform) > repository secret (platform-wide default).

### What goes where

| What | Where | Why |
|---|---|---|
| AWS region, memory, capacity | `Pulumi.<env>.yaml` (committed) | Non-secret, per-environment |
| Platform stack reference | `Pulumi.<env>.yaml` (committed) | Points to correct env's platform |
| Feature flags | `Pulumi.<env>.yaml` (committed) | Per-environment behavior |
| Access tokens, keys | GitHub secrets (never committed) | Authentication credentials |
| Database passwords | `pulumi config --secret` (encrypted in state) | Encrypted per-stack |

**Never** commit secrets to `.env`, `Pulumi.<env>.yaml`, or any file in the repo.

## 10. Troubleshooting

### Stack not found

```
error: no stack named "org/my-app-catalog/alpha" found
```

**Cause**: The Pulumi stack has not been created yet.
**Fix**: Run `pulumi stack init alpha` from the `-aws` package root, or let the GitHub Actions workflow create it on first deployment.

### Missing `platform:stack` config

```
error: Missing required configuration variable 'platform:stack'
```

**Cause**: The plugin's `Pulumi.<env>.yaml` does not include the `platform:stack` key.
**Fix**: Add `platform:stack: org/<platform-project>/<env>` to the plugin's environment config file.

### Cross-stack reference errors

```
error: getting stack reference "org/my-app-catalog/alpha": no stack found
```

**Cause**: The referenced stack (e.g., catalog) has not been deployed yet, but the ordering plugin depends on it.
**Fix**: Deploy the dependency stack first. Check `depends-on` in `deploy-manifest.yaml` to ensure correct ordering. For manual deployments, always deploy dependencies before dependents.

### StackReference output is `undefined`

**Cause**: The dependency stack deployed but did not export the expected output (e.g., `_interopMeta` or `extensionPoints`).
**Fix**: Verify the dependency plugin calls `Platform.deployPlugin(...)` (not `makePlatform`). Redeploy the dependency stack.

### Plugin schema not appearing in API

**Cause**: The plugin deployed successfully but its schema fragment is not in the unified API.
**Fix**: The schema is registered at runtime when the plugin connects. Check that the plugin's Lambda is running and can reach the PluginExtensionPoint (SQS queue). Verify the connect event was processed by checking the admin Plugin read model.

### `Pulumi.<branch>.yaml` not found (deployment skipped)

**Cause**: The branch name does not match any environment config file.
**Fix**: This is expected behavior for feature branches. If you want the branch to deploy, create a `Pulumi.<branch>.yaml` file in the relevant `-aws` packages.

### ReScript compilation error in `-aws` package

**Cause**: Missing dependency in `rescript.json` or the plugin package has not been built.
**Fix**: Ensure `rescript.json` in the `-aws` package lists all required dependencies including the plugin package. Run `pnpm run build` from the monorepo root before deploying.

### Platform redeployment required after framework upgrade

After upgrading `@reventlessdev/reventless-aws` or `@reventlessdev/reventless-spec`, redeploy the platform stack first, then all plugin stacks. The GitHub Actions workflow handles this automatically when it detects changes in framework packages.

## Reference Implementation

The `examples/online-shop-hybrid/` directory in the reventless-core repo contains a working reference implementation with per-plugin deployment configured for both `alpha` and `main` environments. It follows all patterns described in this guide.
