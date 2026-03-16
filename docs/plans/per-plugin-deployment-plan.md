# Per-Plugin Deployment — Implementation Plan

Based on analysis: `docs/analysis/per-plugin-deployment-strategy.md`

## Goal

Enable independent deployment of each Reventless plugin as a separate Pulumi stack, with a shared platform stack for admin components. Primary target: customer repositories with minimal setup effort.

## Prerequisites

- Familiarity with the analysis document (architecture, decisions, trade-offs)
- AWS account with Pulumi state backend configured
- GitHub Actions enabled on the target repository

## Steps

### Step 1: Implement `Platform.deployPlugin` in `reventless-aws`

**What**: Add a new `deployPlugin` function to `reventless-aws/src/Platform.res` that deploys a single plugin against an existing platform stack.

**Details**:
- Accepts `~platformStackName: string` to read platform outputs via `Pulumi.StackReference`
- Accepts `~dependencyStacks: array<string>` for cross-plugin EP resolution
- Reads admin EP, scheduler, and API references from the platform stack
- Deploys the single plugin and exports its ExtensionPoint outputs as stack outputs
- Also add `deployPlatform` that deploys only the admin components, scheduler, and shared AppSync API (without any plugins)

**Files**:
- `reventless/reventless-aws/src/Platform.res` — add `deployPlugin` and `deployPlatform`
- `reventless/reventless-core/src/components/Plugin/Plugin_Builder.res` — extract single-plugin deployment logic if needed

**Done when**: A plugin can be deployed standalone via `Platform.deployPlugin` and registers its schema with the platform's AppSync API.

- [ ] Not started

### Step 2: Enhance `Interstack` for multi-stack references

**What**: Generalize the `Interstack` module to support reading from multiple dependency stacks, not just the single `coreStackReference`.

**Details**:
- Support reading ExtensionPoint outputs from other plugin stacks (for Extensions that subscribe to foreign EPs)
- Dependency stack names come from Pulumi config (`Pulumi.<branch>.yaml`)

**Files**:
- `reventless/reventless-core/src/util/Interstack.res` (or equivalent)

**Done when**: A plugin can read EP outputs from both the platform stack and other plugin stacks.

- [ ] Not started

### Step 3: Add `deploy/aws/` to `online-shop-hybrid` example

**What**: Add co-located Pulumi programs to the hybrid example as the reference implementation.

**Details**:
- `online-shop-hybrid/deploy/aws/` — platform stack (`Main.res`, `Pulumi.yaml`, `Pulumi.alpha.yaml`, `Pulumi.main.yaml`)
- `catalog/deploy/aws/` — catalog plugin stack
- `ordering/deploy/aws/` — ordering plugin stack
- `deploy-manifest.yaml` at the example root
- Verify both `npm run dev` (in-memory) and `pulumi up` (AWS) work

**Files**:
- `examples/online-shop-hybrid/online-shop-hybrid/deploy/aws/Main.res`
- `examples/online-shop-hybrid/online-shop-hybrid/deploy/aws/Pulumi.yaml`
- `examples/online-shop-hybrid/online-shop-hybrid/deploy/aws/Pulumi.alpha.yaml`
- `examples/online-shop-hybrid/online-shop-hybrid/deploy/aws/Pulumi.main.yaml`
- `examples/online-shop-hybrid/catalog/deploy/aws/Main.res`
- `examples/online-shop-hybrid/catalog/deploy/aws/Pulumi.yaml`
- `examples/online-shop-hybrid/catalog/deploy/aws/Pulumi.alpha.yaml`
- `examples/online-shop-hybrid/catalog/deploy/aws/Pulumi.main.yaml`
- `examples/online-shop-hybrid/ordering/deploy/aws/` (same structure)
- `examples/online-shop-hybrid/deploy-manifest.yaml`

**Done when**: The hybrid example can be deployed per-plugin to AWS, and `npm run dev` still works for local development.

- [ ] Not started

### Step 4: Create the reusable GitHub Actions workflow

**What**: Publish `deploy-reventless-aws.yml` as a reusable workflow from this repo.

**Details**:
- Inputs: `manifest` path, `node-version`
- Secrets: `PULUMI_ACCESS_TOKEN`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `NPM_TOKEN`
- Branch name extracted as Pulumi stack name (no hardcoded mapping)
- Checks `Pulumi.<branch>.yaml` existence — skips if missing
- Checks for `[skip deploy]` in commit message
- `push` events → `pulumi up` (deploy)
- `pull_request` events → `pulumi preview` (dry run, posted as PR comment)
- Change detection reads `deploy-manifest.yaml`
- Platform deploys first, then plugins in parallel (respecting `depends-on`)
- Per-plugin GitHub environment secret resolution via `environment: deploy-${{ matrix.plugin }}`

**Files**:
- `.github/workflows/deploy-reventless-aws.yml`

**Done when**: A customer repo can call this workflow with a 15-line YAML file and get full per-plugin deployment.

- [ ] Not started

### Step 5: Create Pulumi template files

**What**: Minimal template files that customers copy into their `deploy/aws/` directories.

**Details**:
- Platform `Main.res` template — calls `Platform.deployPlatform()`
- Plugin `Main.res` template — calls `Platform.deployPlugin()` with config-driven platform stack reference
- `Pulumi.yaml` template — project name placeholder
- `Pulumi.<branch>.yaml` template — region, memory, billing mode placeholders
- `deploy-manifest.yaml` template — plugin name and path placeholders

**Files**:
- Templates in `packages/doc/` or a dedicated templates directory

**Done when**: A customer can copy templates, fill in names, and have a working deployment setup.

- [ ] Not started

### Step 6: Document the deployment guide

**What**: Write the deployment guide in `docs/guides/deployment-guide.md` (see separate guide document).

**Done when**: The guide is complete, reviewed, and covers all customer-facing setup steps.

- [ ] Not started

### Step 7: Build `create-reventless-platform` scaffolding package

**What**: An npm package that scaffolds a complete Reventless project with deployment configuration.

**Details**:
- Interactive CLI: project name, plugin names, cloud provider, environment branches
- Generates: platform package, plugin packages, spec packages, `deploy/<platform>/` directories, `deploy-manifest.yaml`, `.github/workflows/deploy-<platform>.yml`, in-memory dev server `Main.res`
- Published as `@reventlessdev/create-reventless-platform` (or `create-reventless-platform` for `npx` usage)

**Done when**: `npx create-reventless-platform` generates a working project that can be deployed immediately.

- [ ] Not started

## Implementation Order

Steps 1–2 are framework changes (required first). Step 3 validates the approach end-to-end. Steps 4–5 enable customer adoption. Step 6 documents everything. Step 7 is the final polish for developer experience.

Steps 4 and 5 can be done in parallel. Step 7 can be deferred if time is short — the manual setup via templates (Step 5) is sufficient for early adopters.
