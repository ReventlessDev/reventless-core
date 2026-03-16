# Per-Plugin AWS Deployment via GitHub Actions

## Context

Currently, the reventless AWS platform composes all plugins into a single Pulumi program (`Main.res`). All plugins are deployed together as one Pulumi stack. This analysis proposes an architecture where each plugin is deployed independently — triggered by GitHub Actions when files within that plugin change.

## Current State

### Deployment Model

- `Main.res` imports all plugins and calls `Platform.makePlatform(~plugins=[...])`, deploying everything as a single Pulumi stack
- All examples currently use `ReventlessInMemory.Platform`, not AWS — no production Pulumi programs exist in the repo yet
- The AWS Platform (`reventless-aws/src/Platform.res`) uses `MakeWithConfig` with `splitApi` mode (creates separate core and plugin AppSync APIs)
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
- **Shared AppSync API**: In split mode, each plugin pushes to its own API, but admin schema goes to a separate core API.

## Proposal: Per-Plugin Pulumi Stacks

### Architecture

Split the monolithic Pulumi program into **one stack per plugin** plus a **platform stack**:

```
Stacks:
├── platform      # Admin components, Scheduler, Core API (AppSync), Lambda Layer
├── catalog       # CatalogPlugin (aggregates, read models, EPs, extensions, tasks)
└── ordering      # OrderingPlugin (aggregates, read models, EPs, extensions, tasks)
```

### Stack Structure

#### Platform Stack (`infrastructure/platform/`)

Deploys shared platform resources:
- AppSync API (core) with admin schema
- Platform Admin (Plugin aggregate, read model, extension point, cloner)
- Scheduler (CloudWatch)
- Lambda Layer reference

**Exports** (via Pulumi stack outputs):
- `extensionPoints` — serialized EP data (CommandTopic ARN, EventTopic ARN) for plugin stacks to consume
- `schedulerArn` — Scheduler operations for plugin heartbeats
- `coreApi` / `coreRole` — AppSync API references (for split mode)

#### Plugin Stacks (`infrastructure/plugins/<plugin-name>/`)

Each plugin stack:
1. Reads platform stack outputs via `Pulumi.StackReference`
2. Creates its own AppSync API (split mode) or pushes to shared API
3. Deploys all plugin-specific infrastructure
4. Exports its own `extensionPoints` for other plugins that depend on it

**Cross-plugin resolution**: Plugin B's Extension that subscribes to Plugin A's ExtensionPoint reads Plugin A's stack outputs via `StackReference`.

### Pulumi Program Structure

```
infrastructure/
├── platform/
│   ├── Pulumi.yaml
│   ├── Pulumi.<env>.yaml
│   └── index.ts              # Thin wrapper calling ReScript
├── plugins/
│   ├── catalog/
│   │   ├── Pulumi.yaml
│   │   ├── Pulumi.<env>.yaml
│   │   └── index.ts
│   └── ordering/
│       ├── Pulumi.yaml
│       ├── Pulumi.<env>.yaml
│       └── index.ts
└── shared/
    └── stack-config.ts       # Environment/region config shared across stacks
```

### ReScript Entry Points

Each plugin stack needs its own `Main.res` that:
1. Creates the AWS Platform (with API + role)
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

### GitHub Actions Workflow

#### Change Detection Strategy

Use **path filters** combined with a **dynamic matrix** to deploy only changed plugins:

```yaml
name: Deploy Plugins

on:
  push:
    branches: [main]
    paths:
      - 'infrastructure/**'
      - 'examples/**'
      - 'reventless/**'

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      platform-changed: ${{ steps.changes.outputs.platform }}
      changed-plugins: ${{ steps.changes.outputs.plugins }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Detect changed plugins
        id: changes
        run: |
          # Compare against previous commit on main
          BASE_SHA="${{ github.event.before }}"
          HEAD_SHA="${{ github.sha }}"

          # Platform changes: framework packages or platform infrastructure
          PLATFORM_CHANGED="false"
          if git diff --name-only $BASE_SHA $HEAD_SHA | grep -qE '^(reventless/reventless-(core|aws|infra|spec)/|infrastructure/platform/)'; then
            PLATFORM_CHANGED="true"
          fi
          echo "platform=$PLATFORM_CHANGED" >> $GITHUB_OUTPUT

          # Plugin changes: detect which plugin directories changed
          CHANGED_PLUGINS="[]"
          PLUGINS=$(ls -d infrastructure/plugins/*/ 2>/dev/null | xargs -I{} basename {})
          PLUGIN_LIST=()
          for plugin in $PLUGINS; do
            # Check plugin infrastructure AND plugin source code
            if git diff --name-only $BASE_SHA $HEAD_SHA | grep -qE "^(infrastructure/plugins/$plugin/|examples/[^/]+/$plugin/)"; then
              PLUGIN_LIST+=("\"$plugin\"")
            fi
          done

          # If platform changed, deploy ALL plugins (infrastructure may have changed)
          if [ "$PLATFORM_CHANGED" = "true" ]; then
            PLUGIN_LIST=()
            for plugin in $PLUGINS; do
              PLUGIN_LIST+=("\"$plugin\"")
            done
          fi

          CHANGED_PLUGINS="[$(IFS=,; echo "${PLUGIN_LIST[*]}")]"
          echo "plugins=$CHANGED_PLUGINS" >> $GITHUB_OUTPUT

  deploy-platform:
    needs: [detect-changes]
    if: needs.detect-changes.outputs.platform-changed == 'true'
    runs-on: ubuntu-latest
    environment: deploy-platform
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-node@v6
        with:
          node-version: "22.17.1"
          cache: "npm"
          registry-url: "https://npm.pkg.github.com"

      - run: npm ci
        env:
          NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - run: npm run build

      - uses: pulumi/actions@v6
        with:
          command: up
          stack-name: org/platform/${{ vars.PULUMI_ENV }}
          work-dir: infrastructure/platform
        env:
          PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          AWS_REGION: ${{ vars.AWS_REGION }}

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
      max-parallel: 2  # Limit parallel deployments to avoid rate limits
      fail-fast: false  # Don't cancel other plugins if one fails
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-node@v6
        with:
          node-version: "22.17.1"
          cache: "npm"
          registry-url: "https://npm.pkg.github.com"

      - run: npm ci
        env:
          NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - run: npm run build

      - uses: pulumi/actions@v6
        with:
          command: up
          stack-name: org/${{ matrix.plugin }}/${{ vars.PULUMI_ENV }}
          work-dir: infrastructure/plugins/${{ matrix.plugin }}
        env:
          PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          AWS_REGION: ${{ vars.AWS_REGION }}
```

#### Deployment Order

1. **Platform first** — always deploy platform before plugins (if platform changed)
2. **Plugins in parallel** — independent plugins deploy concurrently
3. **Dependent plugins sequentially** — if Plugin B depends on Plugin A's ExtensionPoint, B must deploy after A

For dependency ordering, add a plugin dependency manifest:

```yaml
# infrastructure/plugin-dependencies.yaml
catalog:
  depends-on: []      # No plugin dependencies (only platform)
ordering:
  depends-on:
    - catalog          # OrdersExtension subscribes to CatalogSpec.ProductsExtensionPoint
```

The workflow would parse this to build a deployment DAG and deploy in topological order.

### Plugin Registration / Discovery

Two approaches for discovering which plugins exist:

#### Option A: Convention-based (recommended)

Plugins are discovered by directory structure:
- `infrastructure/plugins/<name>/` — each subdirectory is a deployable plugin
- Plugin source code mapping defined in `infrastructure/plugins/<name>/plugin-config.yaml`:
  ```yaml
  source-paths:
    - examples/online-shop-aggregates/catalog/
    - examples/online-shop-aggregates/catalog-spec/
  depends-on: []
  ```

#### Option B: Manifest-based

A central `infrastructure/plugins.yaml` lists all plugins, their source paths, and dependencies. Simpler but requires manual maintenance.

### Secret Management

Secrets (Pulumi access tokens, AWS credentials) are managed entirely in GitHub — **not** in `.env` files, not in the repository, and not in Pulumi config. GitHub provides two scoping levels that combine to give per-plugin or platform-wide token flexibility.

#### Where Secrets Live

| Scope | Where to set it | Who can use it |
|---|---|---|
| **Repository secret** | GitHub repo → Settings → Secrets and variables → Actions → Repository secrets | Every job in every workflow |
| **Environment secret** | GitHub repo → Settings → Environments → `<env>` → Environment secrets | Only jobs with `environment: <env>` |

Environment secrets with the **same name** as a repository secret **override** the repository secret for that job. This is the mechanism that makes per-plugin tokens work.

#### Step-by-Step Setup

##### 1. Set platform-wide defaults (repository secrets)

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

Also set **repository variables** (Settings → Secrets and variables → Actions → Variables tab):

| Name | Value | Purpose |
|---|---|---|
| `AWS_REGION` | `eu-west-1` | Default AWS region |
| `PULUMI_ENV` | `prod` (for main) | Pulumi stack environment suffix |

##### 2. Create GitHub Environments

Create one environment per deployment target. At minimum: `deploy-platform` and one `deploy-<plugin>` per plugin.

1. Go to **Settings** → **Environments**
2. Click **New environment**
3. Name it `deploy-platform` → click **Configure environment**
4. (Optional) Add **protection rules**:
   - Required reviewers — require approval before deploying to production
   - Wait timer — delay deployment (e.g., 5 minutes for manual abort)
   - Deployment branches — restrict to `main`, `beta`, `alpha`
5. Repeat for each plugin: `deploy-catalog`, `deploy-ordering`, etc.

##### 3. Set per-plugin secrets (optional — only where you need different tokens)

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

##### 4. Verify the setup

Run the workflow manually (workflow_dispatch) or push a change. In the GitHub Actions run log:
- Each `deploy-<plugin>` job shows its environment name in the job header
- If an environment has protection rules, the job pauses for approval
- Secret values are masked in logs (shown as `***`)

#### How the Workflow References Secrets

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

#### What NOT to Do

- **Never commit secrets** to `.env`, `Pulumi.<env>.yaml`, or any file in the repo
- **Never use `pulumi config --secret`** for access tokens — those go in Pulumi's state backend, not GitHub
- **Never hardcode** ARNs, tokens, or keys in workflow YAML — always use `${{ secrets.* }}` or `${{ vars.* }}`
- `Pulumi.<env>.yaml` is for **non-secret stack configuration** only (region, instance sizes, feature flags)

### Environment Strategy

Each environment gets its own set of Pulumi stacks:

```
org/platform/dev      org/platform/staging      org/platform/prod
org/catalog/dev       org/catalog/staging       org/catalog/prod
org/ordering/dev      org/ordering/staging      org/ordering/prod
```

Branch mapping:
- `alpha` → dev environment
- `beta` → staging environment
- `main` → prod environment

## Deployment Scenarios

### Scenario 1: Plugin source code change only

A developer changes `CatalogPlugin.res` behavior logic:
1. Change detection finds `examples/online-shop-aggregates/catalog/` modified
2. Platform stack not affected → skip platform deployment
3. Only `catalog` plugin stack deploys → new Lambda code, no infra changes
4. Other plugins unaffected

### Scenario 2: Framework change

A developer modifies `reventless-core/src/components/Plugin/Plugin_Builder.res`:
1. Change detection finds `reventless/reventless-core/` modified → platform changed
2. Platform stack deploys first (admin components may be affected)
3. All plugin stacks deploy (framework change could affect any plugin)

### Scenario 3: New plugin added

A developer adds a new `shipping` plugin:
1. Creates `infrastructure/plugins/shipping/` with Pulumi config
2. Creates plugin source under `examples/` or a dedicated directory
3. Adds `shipping` entry to plugin-dependencies.yaml
4. First deployment creates all resources from scratch

### Scenario 4: Cross-plugin dependency change

Catalog adds a new ExtensionPoint that Ordering will consume:
1. Deploy `catalog` first (creates the new EP, exports outputs)
2. Deploy `ordering` after (reads catalog's new EP outputs via StackReference)
3. Dependency graph ensures correct order

## Trade-offs

### Advantages

- **Faster deployments**: Only changed plugins deploy (seconds instead of minutes)
- **Blast radius reduction**: A bad deployment affects only one plugin
- **Independent lifecycle**: Plugins can be versioned and rolled back independently
- **Parallel deployment**: Independent plugins deploy concurrently
- **Team autonomy**: Different teams can own different plugins

### Disadvantages

- **Cross-stack coordination**: Extensions ↔ ExtensionPoints require StackReferences, adding latency and coupling
- **Framework changes redeploy everything**: Core changes trigger full deployment anyway
- **More Pulumi stacks to manage**: N plugins → N+1 stacks per environment
- **State management complexity**: Each stack has its own state file; cross-stack references can drift
- **Framework API changes required**: Need `deployPlugin` + enhanced `Interstack` module

### Risks

- **StackReference drift**: If Plugin A redeploys and changes its EP outputs, Plugin B may fail until redeployed
- **Partial deployment failures**: Plugin A deploys but Plugin B fails — system in inconsistent state
- **Lambda Layer version mismatch**: All plugins must use the same Lambda Layer version; independent deploys could cause version skew

## Open Questions

1. **Plugin source code location**: Should plugin code live under `infrastructure/plugins/<name>/src/` (co-located with Pulumi config) or remain under `examples/` (current structure)?

2. **Shared resources**: Should the AppSync API be in the platform stack or per-plugin? Split API mode naturally fits per-plugin stacks, but unified mode requires a shared API managed by the platform.

3. **Rollback strategy**: Should rollbacks be per-plugin (Pulumi stack rollback) or coordinated across dependent plugins?

4. **Preview/PR deployments**: Should PRs trigger `pulumi preview` for changed plugins to catch deployment issues before merge?

5. **Stack naming convention**: How should stacks reference each other? By convention (`org/<plugin>/<env>`, `org/platform/<env>`) or via configuration?

## Recommendation

Start with the **convention-based discovery** (Option A) and **split API mode** (which already isolates plugin APIs). The initial implementation should:

1. Create `infrastructure/` directory structure with platform + plugin stacks
2. Implement `Platform.deployPlugin` in the framework (single-plugin deployment)
3. Enhance `Interstack` to support multi-stack references
4. Add the GitHub Actions workflow with change detection + dependency-ordered deployment
5. Add `pulumi preview` on PRs for affected stacks

This can be implemented incrementally — start with the platform stack and one plugin, then migrate additional plugins one at a time.
