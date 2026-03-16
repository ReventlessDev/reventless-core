# Per-Plugin Deployment Strategy

## Context

Reventless applications are composed of **plugins** deployed on a **platform** (AWS, in-memory, or future providers). Currently, all plugins are deployed together as a single Pulumi program. This analysis proposes an architecture where each plugin is deployed independently — triggered by GitHub Actions when files within that plugin change.

The **primary audience** is customers building their own applications in separate repositories that depend on the published `@reventlessdev/*` packages. The examples in this monorepo (`examples/online-shop-*`) serve as reference implementations and should follow the same patterns.

## Current State

### Deployment Model

- `Main.res` imports all plugins and calls `Platform.makePlatform(~plugins=[...])`, deploying everything as a single Pulumi stack
- All examples currently use `ReventlessInMemory.Platform`, not AWS — no production Pulumi programs exist in the repo yet
- The AWS Platform (`reventless-aws/src/Platform.res`) uses `MakeWithConfig` with `splitApi` mode (creates separate admin and plugin AppSync APIs)
- Admin components (Plugin aggregate, read model, extension point, cloner) are created internally by `makePlatform`

### Infrastructure Per Plugin

Each plugin creates the following AWS resources:
- **EventLog**: DynamoDB table + stream (per aggregate / DCB event log)
- **CommandTopic**: SQS FIFO queue (per aggregate / DCB slice)
- **EventTopic**: SNS FIFO / DynamoDB Streams (per aggregate / DCB event log)
- **QueryDb**: DynamoDB table (per read model / state view slice)
- **EventCollector**: SQS FIFO subscriptions to event topics
- **Lambda functions**: per aggregate handler, event collector, DCB command handler, tasks
- **Task buckets**: S3 (per task)
- **Heartbeat**: CloudWatch Events Rule
- **AppSync schema**: pushed to the shared or plugin-specific AppSync API

### Cross-Plugin Dependencies

- **Extensions ↔ ExtensionPoints**: A plugin's Extension subscribes to another plugin's ExtensionPoint. The Extension needs the EP's `commandTopic.resources` (SQS ARN) and `eventTopic.resources` (SNS ARN). Currently resolved at deploy-time via Pulumi's resource graph (same stack) or `Interstack` (cross-stack `StackReference`).
- **Admin ExtensionPoint**: All plugins connect to the Platform Admin's `PluginExtensionPoint`. Resolved via `StackReference` (AWS) or local refs (in-memory).
- **Shared Scheduler**: Created once by `makePlatform`, passed to all plugins.
- **Shared AppSync API**: In split mode, each plugin pushes to its own API, but admin schema goes to a separate admin API.

## Proposal: Per-Plugin Pulumi Stacks

### Architecture

Split the monolithic Pulumi program into **one stack per plugin** plus a **platform stack**:

```
Stacks:
├── platform      # Admin components, Scheduler, Admin API (AppSync), Lambda Layer
├── catalog       # CatalogPlugin (aggregates, read models, EPs, extensions, tasks)
└── ordering      # OrderingPlugin (aggregates, read models, EPs, extensions, tasks)
```

### Stack Structure

#### Platform Stack

Deploys shared platform resources:
- AppSync API (admin) with admin schema
- Platform Admin (Plugin aggregate, read model, extension point, cloner)
- Scheduler (CloudWatch)
- Lambda Layer reference

**Exports** (via Pulumi stack outputs):
- `extensionPoints` — serialized EP data (CommandTopic ARN, EventTopic ARN) for plugin stacks to consume
- `schedulerArn` — Scheduler operations for plugin heartbeats
- `adminApi` / `adminRole` — AppSync API references (for split mode)

#### Plugin Stacks

Each plugin stack:
1. Reads platform stack outputs via `Pulumi.StackReference`
2. Deploys all plugin-specific infrastructure
3. Generates its own **API schema fragment** and registers it with the platform (see below)
4. Exports its own `extensionPoints` for other plugins that depend on it

**Cross-plugin resolution**: Plugin B's Extension that subscribes to Plugin A's ExtensionPoint reads Plugin A's stack outputs via `StackReference`.

### API Schema Registration

Each plugin generates a **GraphQL schema fragment** containing its mutations (from aggregates and DCB slices) and queries (from read models and state view slices). This fragment is not baked into the platform at deploy time — instead, plugins **register their fragments dynamically** with the platform's API.

#### How it works

1. **Plugin generates fragment**: During `Plugin_Builder.construct`, the plugin derives its schema fragment from `Spec.commandSchema`, `Spec.stateSchema`, and the naming conventions in `Api_Naming`. This produces SDL types, mutations, and queries specific to that plugin.

2. **Plugin registers fragment with platform API**: The plugin pushes its schema fragment to the platform's AppSync API (or equivalent). On AWS, this happens via `AppSync_Adapter.updateSchema` — the plugin stack calls the platform API to merge its fragment into the running schema. On in-memory, the `schemaTypeRegistrationHook` and `mutationResolverHook` register types and resolvers directly into the GraphQL server.

3. **Platform adapts dynamically**: The platform API receives schema fragments from plugins and **stitches them together** at runtime. When a plugin redeploys with a changed schema (new mutations, renamed fields, added queries), the platform API updates its schema automatically — no platform redeployment needed.

4. **Independent schema lifecycle**: Each plugin owns its schema fragment. Adding a field to a read model or a new command to an aggregate only requires redeploying that plugin. The platform's unified schema reflects the change as soon as the plugin pushes its updated fragment.

#### Per-plugin deployment implications

- The **platform stack** deploys the admin schema (Plugin queries, cloner mutations) and creates the API endpoint. It does not know about plugin schemas at deploy time.
- Each **plugin stack** pushes its fragment after deployment. The platform API merges all registered fragments into the unified schema.
- If a plugin is removed (stack destroyed), its schema fragment is deregistered and the platform API no longer serves those fields.
- Schema conflicts (two plugins defining the same type name) are caught at registration time, not at platform deploy time.

### Co-located Pulumi Programs

Pulumi programs live **directly inside the platform and plugin packages** — next to the code they deploy. This keeps deployment config close to the source and avoids a parallel directory hierarchy.

Each plugin package gets a `deploy/` directory containing platform-specific Pulumi programs. The composition root package (which wires all plugins for in-memory dev) also gets a `deploy/` directory for the **platform stack** deployment.

```
my-app/                                       # Customer repository
├── catalog-spec/                             # Spec package (types, EP specs)
├── catalog/                                  # Plugin package (platform-agnostic)
│   ├── src/CatalogPlugin.res
│   └── deploy/
│       └── aws/                              # AWS deployment for this plugin
│           ├── Pulumi.yaml
│           ├── Pulumi.dev.yaml
│           ├── Pulumi.prod.yaml
│           └── Main.res
├── ordering-spec/
├── ordering/
│   ├── src/OrderingPlugin.res
│   └── deploy/
│       └── aws/
│           ├── Pulumi.yaml
│           ├── Pulumi.dev.yaml
│           ├── Pulumi.prod.yaml
│           └── Main.res
├── platform/                                 # Platform deployment + in-memory dev server
│   ├── src/Main.res                          # In-memory dev: all plugins wired together
│   └── deploy/
│       └── aws/                              # Platform stack: admin, scheduler, shared API
│           ├── Pulumi.yaml
│           ├── Pulumi.dev.yaml
│           ├── Pulumi.prod.yaml
│           └── Main.res
├── deploy-manifest.yaml                      # Maps plugins to deploy dirs (see below)
├── package.json                              # Monorepo root
└── .github/
    └── workflows/
        └── deploy-aws.yml                    # Reusable or copied from template
```

### Multi-Platform Support

Plugins are already **platform-agnostic** — `CatalogPlugin.Make(Platform)` accepts any `Platform.T`. The platform-specific code is isolated in the `deploy/<platform>/` entry point:

#### AWS entry point (`catalog/deploy/aws/Main.res`)

```rescript
module Platform = ReventlessAws.Platform.Make({
  let api = ...
  let apiRole = ...
})

module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)

Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugin=module(Catalog),
)
```

#### In-memory — no Pulumi needed

The `platform/src/Main.res` continues to work as-is for local development. `npm run dev` starts the GraphQL + MCP servers locally with all plugins wired together. No `deploy/` directory is involved.

#### Future platforms (Azure, GCP, Supabase)

Add a new `deploy/<platform>/` directory when a new platform implementation exists:

```
catalog/deploy/
├── aws/          # Uses reventless-aws Platform
├── azure/        # Would use a future reventless-azure Platform
└── supabase/     # Would use a future reventless-supabase Platform
```

Each platform directory is a self-contained Pulumi project with its own `Pulumi.yaml`. They share the same plugin source code — only the infrastructure wiring differs. A plugin can be deployed to multiple platforms simultaneously (different stacks).

### Environments — Branch Name Is the Stack Name

Environments are **not hardcoded** in the workflow or in any mapping table. Instead, the **git branch name is used directly as the Pulumi stack name**. Deployment only happens if a matching `Pulumi.<branch>.yaml` file exists in the plugin's `deploy/` directory.

#### How it works

1. The workflow extracts the branch name from the push event (e.g., `main`, `alpha`, `test`, `feature-x`)
2. For each deployable component (platform + plugins), it checks whether `Pulumi.<branch>.yaml` exists in the component's `deploy/<platform>/` directory
3. **If the file exists** → deploy using that stack configuration
4. **If the file does not exist** → skip deployment entirely for that component

This means:
- Adding a new environment = creating `Pulumi.<branch>.yaml` files in each deploy directory
- Removing an environment = deleting those files
- Feature branches don't deploy unless you explicitly add a `Pulumi.<branch>.yaml` for them
- No workflow changes needed when environments are added or removed

#### Branch naming convention

Since the branch name is used directly as the Pulumi stack name, **branches must be named after the environment they deploy to**. The `main` branch is **not** used for active development — it is reserved for production deployments.

**Customer projects** should use environment-named branches:

| Branch | Environment | Purpose |
|---|---|---|
| `dev` | Development | Active development, frequent deploys |
| `test` | Test | Pre-production verification |
| `prod` | Production | Stable releases only |

Feature branches (e.g., `feature-xyz`) have no `Pulumi.<branch>.yaml` and therefore never trigger deployment.

**Example projects** (in this monorepo) follow the existing release branch convention:

| Branch | Environment | Purpose |
|---|---|---|
| `alpha` | Alpha pre-release | Framework development |
| `beta` | Beta pre-release | Stabilization |
| `main` | Production | Stable release |

The branch names don't matter to the workflow — what matters is that a `Pulumi.<branch>.yaml` file exists. Each team chooses its own branch naming convention.

#### Pulumi files per deploy directory

```
catalog/deploy/aws/
├── Pulumi.yaml              # Project definition (name, runtime) — shared across all envs
├── Pulumi.dev.yaml          # Config for the dev branch
├── Pulumi.test.yaml         # Config for the test branch (if used)
├── Pulumi.prod.yaml         # Config for the prod branch
└── Main.res                 # Entry point — same for all environments
```

Only branches with a matching `Pulumi.<branch>.yaml` trigger deployment. A push to `feature-xyz` does nothing unless `Pulumi.feature-xyz.yaml` exists.

#### Example Pulumi stack configs

**`Pulumi.yaml`** (project — same for all environments):
```yaml
name: my-app-catalog
runtime: nodejs
description: Catalog plugin — AWS deployment
```

**`Pulumi.dev.yaml`** (dev environment):
```yaml
config:
  aws:region: eu-west-1
  my-app-catalog:platformStack: org/my-app-platform/dev
  my-app-catalog:lambdaMemory: 256
  my-app-catalog:dynamoDbBillingMode: PAY_PER_REQUEST
```

**`Pulumi.prod.yaml`** (production environment):
```yaml
config:
  aws:region: eu-west-1
  my-app-catalog:platformStack: org/my-app-platform/prod
  my-app-catalog:lambdaMemory: 1024
  my-app-catalog:dynamoDbBillingMode: PROVISIONED
  my-app-catalog:dynamoDbReadCapacity: 100
  my-app-catalog:dynamoDbWriteCapacity: 50
```

Note how the `platformStack` reference also uses the branch/stack name (`dev`, `prod`) — so the platform and plugins always deploy to matching environments.

#### Selecting the environment at deploy time

```bash
# Deploy catalog using the dev stack config
pulumi up --stack dev --cwd catalog/deploy/aws/

# Deploy catalog using the prod stack config
pulumi up --stack prod --cwd catalog/deploy/aws/
```

In GitHub Actions, the branch name is extracted automatically — no mapping needed.

#### Full stack naming across all plugins and environments

```
org/my-app-platform/dev       org/my-app-platform/test       org/my-app-platform/prod
org/my-app-catalog/dev        org/my-app-catalog/test        org/my-app-catalog/prod
org/my-app-ordering/dev       org/my-app-ordering/test       org/my-app-ordering/prod
```

#### What goes in Pulumi config vs. GitHub secrets

| What | Where | Why |
|---|---|---|
| AWS region, memory sizes, capacity | `Pulumi.<branch>.yaml` (committed) | Non-secret, differs per environment |
| Platform stack reference name | `Pulumi.<branch>.yaml` (committed) | Points to the correct environment's platform stack |
| Feature flags, toggles | `Pulumi.<branch>.yaml` (committed) | Environment-specific behavior |
| Pulumi access token | GitHub secret (never committed) | Authentication credential |
| AWS access key / secret | GitHub secret (never committed) | Authentication credential |
| Database passwords, API keys | `pulumi config --secret` (encrypted in state) | Encrypted per-stack, never in plaintext |

#### Adding or removing environments

| Action | What to do | Workflow change needed? |
|---|---|---|
| Add `test` environment | Create `test` branch + `Pulumi.test.yaml` in every `deploy/aws/` dir | No |
| Add temporary `demo` environment | Create `demo` branch + `Pulumi.demo.yaml` in relevant deploy dirs | No |
| Remove `dev` environment | Delete `Pulumi.dev.yaml` files | No |
| Feature branches | Don't create `Pulumi.<branch>.yaml` → no deploy | No |

### ReScript Entry Points

Each plugin stack needs its own entry point that:
1. Creates the platform (AWS, Azure, etc.) with the correct provider config
2. Instantiates only its own plugin module
3. Calls a new `Platform.deployPlugin` (instead of `makePlatform`) that:
   - Reads platform stack outputs for admin EP + scheduler
   - Deploys the single plugin
   - Exports the plugin's extension points as stack outputs

This requires a **new framework API**: `Platform.deployPlugin` (single-plugin deployment) alongside the existing `Platform.makePlatform` (multi-plugin, single-stack).

### Framework Changes Required

1. **`Platform.deployPlugin`** — new function in `Platform.res` (both AWS and in-memory):
   ```rescript
   let deployPlugin = (
     ~version: string,
     ~platformStackName: string,     // StackReference to platform
     ~dependencyStacks: array<string>, // StackReferences to other plugin stacks
     ~plugin: module(PluginMaker),
   ) => unit
   ```

2. **Plugin stack output serialization** — each plugin must export its ExtensionPoint resolved outputs in a format consumable by `StackReference.getOutput`.

3. **`Interstack` module enhancement** — generalize to support reading from multiple dependency stacks (currently only reads from a single `coreStackReference` for the platform stack).

## Customer Repository Setup

This section describes the minimal steps a customer needs to take to enable per-plugin deployment in their own repository.

### What Reventless Provides

To minimize customer effort, the reventless framework should ship:

1. **Reusable GitHub Actions workflow** — published from this repo as a [reusable workflow](https://docs.github.com/en/actions/sharing-automations/reusing-workflows) that customer repos call with minimal configuration.

2. **`deploy-manifest.yaml` template** — a documented example manifest that customers copy and fill in with their plugin names and paths.

3. **Pulumi program templates** — minimal `Pulumi.yaml` + `Main.res` files for both platform and plugin stacks, ready to copy into `deploy/aws/`.

### Step-by-Step: New Customer Repository

#### 1. Create `deploy-manifest.yaml` at the repo root

This is the **only deployment-specific file** customers must author from scratch. It maps plugin names to source paths and deploy directories:

```yaml
# deploy-manifest.yaml
platform:
  deploy-dir: platform/deploy/aws

plugins:
  catalog:
    source-paths:
      - catalog/
      - catalog-spec/
    deploy-dir: catalog/deploy/aws
    depends-on: []

  ordering:
    source-paths:
      - ordering/
      - ordering-spec/
    deploy-dir: ordering/deploy/aws
    depends-on:
      - catalog
```

#### 2. Add `deploy/aws/` to each plugin and platform package

Copy the template files into each package. At minimum, each `deploy/aws/` contains:

```
deploy/aws/
├── Pulumi.yaml              # Project name + runtime (copy from template, change name)
├── Pulumi.dev.yaml          # Config for dev branch (copy from template, adjust)
├── Pulumi.prod.yaml         # Config for prod branch
└── Main.res                 # Entry point (copy from template, change plugin import)
```

Only branches with a matching `Pulumi.<branch>.yaml` file trigger deployment. No file = no deploy.

The `Main.res` for a plugin is a few lines:

```rescript
module Platform = ReventlessAws.Platform.Make({
  let api = ...
  let apiRole = ...
})

module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)

Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugin=module(Catalog),
)
```

The platform `Main.res` is similarly short — it calls `Platform.deployPlatform()` (admin, scheduler, shared API).

#### 3. Add the GitHub Actions workflow

**Option A: Reusable workflow (recommended — zero maintenance)**

Customer adds a single file `.github/workflows/deploy-aws.yml`:

```yaml
name: Deploy (AWS)

on:
  push:
    branches: ['**']           # All branches — Pulumi.<branch>.yaml gates deployment
  workflow_dispatch:

jobs:
  deploy:
    uses: ReventlessDev/reventless-core/.github/workflows/deploy-reventless-aws.yml@main
    with:
      manifest: deploy-manifest.yaml
      node-version: "22.17.1"
    secrets:
      PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

The workflow triggers on **all branches** but deployment only happens if a `Pulumi.<branch>.yaml` file exists in the deploy directory. No hardcoded branch list needed.

The reusable workflow (hosted in this repo) handles:
- Change detection (reads `deploy-manifest.yaml`)
- Branch name → Pulumi stack name (no mapping — branch name is used directly)
- Skipping deployment when `Pulumi.<branch>.yaml` doesn't exist
- Platform-first, then plugins in parallel
- Dependency ordering from manifest
- Per-plugin GitHub environment secret resolution

**Option B: Copy the workflow (full control)**

Customers who need to customize can copy the full workflow file from the reventless documentation/templates and modify it. This is a one-time copy — updates require manual sync.

#### 4. Configure GitHub secrets

1. Go to the customer's GitHub repo → **Settings** → **Secrets and variables** → **Actions**
2. Add **repository secrets**:

| Name | Value | Purpose |
|---|---|---|
| `PULUMI_ACCESS_TOKEN` | Pulumi access token | Authenticates Pulumi CLI |
| `AWS_ACCESS_KEY_ID` | IAM access key | AWS authentication |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key | AWS authentication |
| `NPM_TOKEN` | GitHub/npm token | Install `@reventlessdev/*` packages |

3. **(Optional)** Create GitHub **environments** for per-plugin secret overrides:
   - Go to **Settings** → **Environments** → **New environment**
   - Name: `deploy-platform`, `deploy-catalog`, `deploy-ordering`, etc.
   - Add environment-specific `PULUMI_ACCESS_TOKEN` or AWS credentials if needed
   - Environment secrets with the **same name** as a repository secret **override** it for that plugin's deployment job

#### 5. Done

Push to `dev` → deploys to the `dev` stack (if `Pulumi.dev.yaml` exists). Push to `prod` → deploys to the `prod` stack. Push to any branch without a `Pulumi.<branch>.yaml` (e.g., feature branches) → no deployment. Only changed plugins deploy.

### What Customers Get Out of the Box

| Concern | How it's handled | Customer effort |
|---|---|---|
| Change detection | Reusable workflow reads `deploy-manifest.yaml` | Write manifest once |
| Environment mapping | Branch name = stack name; `Pulumi.<branch>.yaml` gates deploy | Add one file per branch/env |
| Deployment ordering | `depends-on` in manifest | Declare dependencies |
| Secret management | GitHub repo + environment secrets | Set secrets once |
| Per-plugin isolation | Separate Pulumi stacks per plugin | Add `deploy/aws/` per plugin |
| Multi-platform | Separate `deploy/<platform>/` dirs | Add when needed |
| Rollback | `pulumi up --stack <env>` with previous code | Manual or via workflow_dispatch |

### Example: Applying to reventless-core Examples

The examples in this monorepo follow the same pattern. The differences are:
- `@reventlessdev/*` packages are resolved locally via npm workspaces instead of from the registry
- Branch names follow the monorepo convention (`alpha`, `beta`, `main`), so Pulumi files are named `Pulumi.alpha.yaml`, `Pulumi.main.yaml`, etc.

```
examples/online-shop-aggregates/
├── catalog-spec/
├── catalog/
│   ├── src/CatalogPlugin.res
│   └── deploy/aws/                          # Same structure as customer repos
├── ordering-spec/
├── ordering/
│   ├── src/OrderingPlugin.res
│   └── deploy/aws/
├── online-shop-aggregates/                  # Platform package
│   ├── src/Main.res                         # In-memory dev server
│   └── deploy/aws/                          # Platform stack
└── deploy-manifest.yaml                     # Example-specific manifest
```

## Reusable Workflow Design

The reusable workflow published from this repo (`deploy-reventless-aws.yml`) encapsulates the full deployment logic. Customers never need to understand the internals.

The workflow runs on any branch. It uses the **branch name as the Pulumi stack name** and checks for the existence of `Pulumi.<branch>.yaml` in each deploy directory. If the file is missing, that component is skipped — no deployment, no error. This means environments are defined entirely by which `Pulumi.<branch>.yaml` files exist in the repository, not by any hardcoded branch list.

### Inputs

```yaml
on:
  workflow_call:
    inputs:
      manifest:
        description: "Path to deploy-manifest.yaml"
        type: string
        default: "deploy-manifest.yaml"
      node-version:
        description: "Node.js version"
        type: string
        default: "22.17.1"
    secrets:
      PULUMI_ACCESS_TOKEN:
        required: true
      AWS_ACCESS_KEY_ID:
        required: true
      AWS_SECRET_ACCESS_KEY:
        required: true
      NPM_TOKEN:
        required: true
```

### Jobs

```yaml
jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      platform-changed: ${{ steps.changes.outputs.platform }}
      changed-plugins: ${{ steps.changes.outputs.plugins }}
      stack-name: ${{ steps.env.outputs.stack }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Extract branch name as stack name
        id: env
        run: |
          BRANCH="${GITHUB_REF#refs/heads/}"
          echo "stack=$BRANCH" >> $GITHUB_OUTPUT

      - name: Detect changed plugins
        id: changes
        run: |
          BASE_SHA="${{ github.event.before }}"
          HEAD_SHA="${{ github.sha }}"
          MANIFEST="${{ inputs.manifest }}"

          # Platform changes
          PLATFORM_CHANGED="false"
          PLATFORM_DEPLOY=$(yq '.platform.deploy-dir' "$MANIFEST")
          PLATFORM_SOURCES=$(yq '.platform.source-paths[]' "$MANIFEST" 2>/dev/null || echo "")
          for path in $PLATFORM_SOURCES $PLATFORM_DEPLOY; do
            if git diff --name-only $BASE_SHA $HEAD_SHA | grep -q "^${path}"; then
              PLATFORM_CHANGED="true"
              break
            fi
          done
          echo "platform=$PLATFORM_CHANGED" >> $GITHUB_OUTPUT

          # Plugin changes
          PLUGIN_LIST=()
          for plugin in $(yq '.plugins | keys | .[]' "$MANIFEST"); do
            PATHS=$(yq ".plugins.${plugin}.source-paths[]" "$MANIFEST")
            DEPLOY_DIR=$(yq ".plugins.${plugin}.deploy-dir" "$MANIFEST")
            CHANGED="false"
            for path in $PATHS $DEPLOY_DIR; do
              if git diff --name-only $BASE_SHA $HEAD_SHA | grep -q "^${path}"; then
                CHANGED="true"
                break
              fi
            done
            if [ "$CHANGED" = "true" ] || [ "$PLATFORM_CHANGED" = "true" ]; then
              PLUGIN_LIST+=("\"$plugin\"")
            fi
          done

          CHANGED_PLUGINS="[$(IFS=,; echo "${PLUGIN_LIST[*]}")]"
          echo "plugins=$CHANGED_PLUGINS" >> $GITHUB_OUTPUT

  deploy-platform:
    needs: [detect-changes]
    if: needs.detect-changes.outputs.platform-changed == 'true'
    runs-on: ubuntu-latest
    environment: deploy-platform
    steps:
      - uses: actions/checkout@v6

      - name: Read platform deploy dir and check for stack config
        id: paths
        run: |
          DIR=$(yq '.platform.deploy-dir' ${{ inputs.manifest }})
          STACK="${{ needs.detect-changes.outputs.stack-name }}"
          echo "dir=$DIR" >> $GITHUB_OUTPUT
          if [ ! -f "$DIR/Pulumi.${STACK}.yaml" ]; then
            echo "No Pulumi.${STACK}.yaml found in $DIR — skipping platform deployment"
            echo "skip=true" >> $GITHUB_OUTPUT
          else
            echo "skip=false" >> $GITHUB_OUTPUT
          fi

      - uses: actions/setup-node@v6
        if: steps.paths.outputs.skip != 'true'
        with:
          node-version: ${{ inputs.node-version }}
          cache: "npm"
          registry-url: "https://npm.pkg.github.com"

      - run: npm ci
        if: steps.paths.outputs.skip != 'true'
        env:
          NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}

      - run: npm run build
        if: steps.paths.outputs.skip != 'true'

      - uses: pulumi/actions@v6
        if: steps.paths.outputs.skip != 'true'
        with:
          command: up
          stack-name: ${{ needs.detect-changes.outputs.stack-name }}
          work-dir: ${{ steps.paths.outputs.dir }}
        env:
          PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}

  deploy-plugins:
    needs: [detect-changes, deploy-platform]
    if: |
      always() &&
      needs.detect-changes.outputs.changed-plugins != '[]' &&
      (needs.deploy-platform.result == 'success' || needs.deploy-platform.result == 'skipped')
    runs-on: ubuntu-latest
    environment: deploy-${{ matrix.plugin }}
    strategy:
      matrix:
        plugin: ${{ fromJson(needs.detect-changes.outputs.changed-plugins) }}
      max-parallel: 2
      fail-fast: false
    steps:
      - uses: actions/checkout@v6

      - name: Read plugin deploy dir and check for stack config
        id: paths
        run: |
          DIR=$(yq '.plugins.${{ matrix.plugin }}.deploy-dir' ${{ inputs.manifest }})
          STACK="${{ needs.detect-changes.outputs.stack-name }}"
          echo "dir=$DIR" >> $GITHUB_OUTPUT
          if [ ! -f "$DIR/Pulumi.${STACK}.yaml" ]; then
            echo "No Pulumi.${STACK}.yaml found in $DIR — skipping ${{ matrix.plugin }} deployment"
            echo "skip=true" >> $GITHUB_OUTPUT
          else
            echo "skip=false" >> $GITHUB_OUTPUT
          fi

      - uses: actions/setup-node@v6
        if: steps.paths.outputs.skip != 'true'
        with:
          node-version: ${{ inputs.node-version }}
          cache: "npm"
          registry-url: "https://npm.pkg.github.com"

      - run: npm ci
        if: steps.paths.outputs.skip != 'true'
        env:
          NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}

      - run: npm run build
        if: steps.paths.outputs.skip != 'true'

      - uses: pulumi/actions@v6
        if: steps.paths.outputs.skip != 'true'
        with:
          command: up
          stack-name: ${{ needs.detect-changes.outputs.stack-name }}
          work-dir: ${{ steps.paths.outputs.dir }}
        env:
          PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

### Deployment Order

1. **Platform first** — always deploy platform before plugins (if platform changed)
2. **Plugins in parallel** — independent plugins deploy concurrently
3. **Dependent plugins sequentially** — if Plugin B depends on Plugin A's ExtensionPoint, B must deploy after A

Dependency ordering is declared in `deploy-manifest.yaml` via the `depends-on` field. The workflow parses this to build a deployment DAG and deploy in topological order.

## Secret Management

Secrets (Pulumi access tokens, AWS credentials) are managed entirely in GitHub — **not** in `.env` files, not in the repository, and not in Pulumi config. GitHub provides two scoping levels that combine to give per-plugin or platform-wide token flexibility.

### Where Secrets Live

| Scope | Where to set it | Who can use it |
|---|---|---|
| **Repository secret** | GitHub repo → Settings → Secrets and variables → Actions → Repository secrets | Every job in every workflow |
| **Environment secret** | GitHub repo → Settings → Environments → `<env>` → Environment secrets | Only jobs with `environment: <env>` |

Environment secrets with the **same name** as a repository secret **override** the repository secret for that job. This is the mechanism that makes per-plugin tokens work.

### Step-by-Step Setup

#### 1. Set platform-wide defaults (repository secrets)

These are the fallback tokens used by any plugin that doesn't have its own.

1. Go to the GitHub repository page
2. Click **Settings** → **Secrets and variables** → **Actions**
3. Click **Repository secrets** tab → **New repository secret**
4. Add each of these:

| Name | Value | Purpose |
|---|---|---|
| `PULUMI_ACCESS_TOKEN` | Your default Pulumi access token | Authenticates Pulumi CLI for all stacks |
| `AWS_ACCESS_KEY_ID` | IAM access key for deployment | AWS authentication |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key for deployment | AWS authentication |
| `NPM_TOKEN` | Token for `@reventlessdev/*` packages | Install framework dependencies |

#### 2. Create GitHub Environments (optional)

Only needed if you want per-plugin secrets or deployment protection rules.

1. Go to **Settings** → **Environments**
2. Click **New environment**
3. Name it `deploy-platform` → click **Configure environment**
4. (Optional) Add **protection rules**:
   - Required reviewers — require approval before deploying to production
   - Wait timer — delay deployment (e.g., 5 minutes for manual abort)
   - Deployment branches — restrict to `main`, `beta`, `alpha`
5. Repeat for each plugin: `deploy-catalog`, `deploy-ordering`, etc.

#### 3. Set per-plugin secrets (optional — only where you need different tokens)

For each plugin that needs its own Pulumi token or AWS credentials:

1. Go to **Settings** → **Environments** → click the plugin environment (e.g., `deploy-catalog`)
2. Under **Environment secrets**, click **Add secret**
3. Add `PULUMI_ACCESS_TOKEN` with the plugin-specific token

The value you set here **shadows** the repository-level `PULUMI_ACCESS_TOKEN` for this plugin's deployment job only. All other plugins continue using the repository secret.

You can override any combination of secrets per environment:

| Environment | `PULUMI_ACCESS_TOKEN` | `AWS_ACCESS_KEY_ID` | `AWS_SECRET_ACCESS_KEY` |
|---|---|---|---|
| `deploy-platform` | (uses repo default) | (uses repo default) | (uses repo default) |
| `deploy-catalog` | `plc_catalog_token...` | `AKIA_CATALOG...` | `secret_catalog...` |
| `deploy-ordering` | (uses repo default) | (uses repo default) | (uses repo default) |

In this example, catalog deploys with its own Pulumi token and IAM user, while platform and ordering share the platform-wide credentials.

#### 4. Verify the setup

Run the workflow manually (workflow_dispatch) or push a change. In the GitHub Actions run log:
- Each `deploy-<plugin>` job shows its environment name in the job header
- If an environment has protection rules, the job pauses for approval
- Secret values are masked in logs (shown as `***`)

### How the Workflow References Secrets

The `environment` field on each job determines which secret scope applies:

```yaml
deploy-platform:
  environment: deploy-platform                # ← picks secrets from this environment
  steps:
    - uses: pulumi/actions@v6
      env:
        PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}  # env secret > repo secret

deploy-plugins:
  environment: deploy-${{ matrix.plugin }}    # ← e.g. deploy-catalog, deploy-ordering
  strategy:
    matrix:
      plugin: ${{ fromJson(needs.detect-changes.outputs.changed-plugins) }}
  steps:
    - uses: pulumi/actions@v6
      env:
        PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}  # resolved per-plugin
        AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
        AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

The `${{ secrets.PULUMI_ACCESS_TOKEN }}` expression resolves to:
1. The environment secret on `deploy-catalog` — **if set**
2. The repository secret — **otherwise**

No conditional logic, no `.env` files, no secret values in the repository.

### What NOT to Do

- **Never commit secrets** to `.env`, `Pulumi.<env>.yaml`, or any file in the repo
- **Never use `pulumi config --secret`** for access tokens — those go in Pulumi's state backend, not GitHub
- **Never hardcode** ARNs, tokens, or keys in workflow YAML — always use `${{ secrets.* }}` or `${{ vars.* }}`
- `Pulumi.<env>.yaml` is for **non-secret stack configuration** only (region, instance sizes, feature flags)

## Deployment Scenarios

### Scenario 1: Plugin source code change only

A developer changes `CatalogPlugin.res` behavior logic:
1. Change detection finds `catalog/` modified
2. Platform stack not affected → skip platform deployment
3. Only `catalog` plugin stack deploys → new Lambda code, no infra changes
4. Other plugins unaffected

### Scenario 2: Framework change (reventless-core monorepo)

In the reventless-core monorepo, a developer modifies `reventless-core/src/components/Plugin/Plugin_Builder.res`:
1. Change detection finds `reventless/reventless-core/` modified → platform changed
2. Platform stack deploys first (admin components may be affected)
3. All plugin stacks deploy (framework change could affect any plugin)

In customer repos, framework changes arrive via package version bumps — a change to `package.json` dependencies would trigger the relevant deploy paths.

### Scenario 3: New plugin added

A developer adds a new `shipping` plugin:
1. Creates plugin package with `deploy/aws/` containing `Pulumi.yaml` + environment configs
2. Adds `shipping` entry to `deploy-manifest.yaml`
3. Creates `deploy-shipping` GitHub environment (optional — falls back to repo secrets)
4. First deployment creates all resources from scratch

### Scenario 4: Cross-plugin dependency change

Catalog adds a new ExtensionPoint that Ordering will consume:
1. Deploy `catalog` first (creates the new EP, exports outputs)
2. Deploy `ordering` after (reads catalog's new EP outputs via StackReference)
3. Dependency graph ensures correct order

### Scenario 5: Deploying the same plugin to a second cloud provider

A team wants to run the catalog plugin on Azure in addition to AWS:
1. Add `catalog/deploy/azure/` with Azure-specific `Pulumi.yaml` and entry point
2. Create a second manifest (e.g., `deploy-manifest-azure.yaml`)
3. Add a separate GitHub Actions workflow (`deploy-azure.yml`) calling the Azure reusable workflow
4. Plugin source code is unchanged — only the deployment entry point differs

## Trade-offs

### Advantages

- **Faster deployments**: Only changed plugins deploy (seconds instead of minutes)
- **Blast radius reduction**: A bad deployment affects only one plugin
- **Independent lifecycle**: Plugins can be versioned and rolled back independently
- **Parallel deployment**: Independent plugins deploy concurrently
- **Team autonomy**: Different teams can own different plugins
- **Low customer effort**: Reusable workflow + manifest + template files — customers write ~20 lines of config

### Disadvantages

- **Cross-stack coordination**: Extensions ↔ ExtensionPoints require StackReferences, adding latency and coupling
- **Framework changes redeploy everything**: Platform changes trigger full deployment anyway
- **More Pulumi stacks to manage**: N plugins → N+1 stacks per environment
- **State management complexity**: Each stack has its own state file; cross-stack references can drift
- **Framework API changes required**: Need `deployPlugin` + enhanced `Interstack` module

### Risks

- **StackReference drift**: If Plugin A redeploys and changes its EP outputs, Plugin B may fail until redeployed
- **Partial deployment failures**: Plugin A deploys but Plugin B fails — system in inconsistent state
- **Lambda Layer version mismatch**: All plugins must use the same Lambda Layer version; independent deploys could cause version skew

## Open Questions

1. **Shared resources**: Should the AppSync API be in the platform stack or per-plugin? Split API mode naturally fits per-plugin stacks, but unified mode requires a shared API managed by the platform.

2. **Rollback strategy**: Should rollbacks be per-plugin (Pulumi stack rollback) or coordinated across dependent plugins?

3. **Preview/PR deployments**: Should PRs trigger `pulumi preview` for changed plugins to catch deployment issues before merge?

4. **Manifest per platform vs. single manifest**: Should there be one `deploy-manifest.yaml` per cloud provider, or a single manifest with platform sections?

5. **Template distribution**: Should Pulumi templates be distributed as an npm package (`npx create-reventless-deploy`), a GitHub template repo, or documented copy-paste files?

## Recommendation

Start with **co-located `deploy/aws/` directories** and a **reusable GitHub Actions workflow**. The initial implementation should:

1. Implement `Platform.deployPlugin` in the framework (single-plugin deployment)
2. Enhance `Interstack` to support multi-stack references
3. Create the reusable workflow (`deploy-reventless-aws.yml`) in this repo
4. Create Pulumi template files for platform and plugin stacks
5. Add `deploy/aws/` to one example (e.g., `online-shop-aggregates`) as reference
6. Document the customer setup in the Docusaurus docs
7. Add `pulumi preview` on PRs for affected stacks

This can be implemented incrementally — start with the platform stack and one plugin, then migrate additional plugins one at a time. Additional cloud providers can be added later by creating new `deploy/<platform>/` directories and reusable workflows without touching plugin source code.
