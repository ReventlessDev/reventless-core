# Analysis: Automated AWS Lambda Layer Creation

## Goal

Every time `@reventlessdev/reventless-aws` is released, automatically create an AWS Lambda layer containing all its runtime dependencies. Applications deployed to AWS use this layer so only application-specific code needs to be deployed.

---

## Current State

### What Exists

**`packages/aws-lambda-layer/`** — a two-part system:

1. **Generic library** (`src/index.js`) — reusable layer builder using npm's `@npmcli/arborist` (dependency resolution) and `pacote` (package extraction). Accepts configuration for source package, exclusions, and post-processing hooks.

2. **Reventless builder** (`builder/index.js`) — configures the library for `@reventless/reventless-aws` with:
   - Scope exclusions: `@pulumi`, `@types`, `@opentelemetry`
   - Module exclusions: `aws-sdk`
   - Post-processing: removes `.res`/`.resi` source files, PPX binaries, test dirs, unnecessary moment.js artifacts
   - Precompiled modules: `@rescript/core@1.6.1`, `@rescript-labs/decco@2.0.4`, `bs-moment@0.8.0`, `decco@1.6.0` (checked into `builder/precompiled/`)

**Lambda integration** (`rescript/rescript-pulumi-aws/src/Lambda/Lambda.res:50,108-111`):
```rescript
@val external reventlessLayerArn: option<string> = "process.env.REVENTLESS_LAYER_ARN"

// In CallbackFunction.Args.make:
~layers=reventlessLayerArn
  ->Option.map(arn => [arn->Pulumi.Input.make])
  ->Option.getOr([])
  ->Pulumi.Input.make,
```
Applications set `REVENTLESS_LAYER_ARN` env var and all Lambda functions automatically include the layer.

**Release workflow** (`.github/workflows/release.yml`):
- Triggers on push to `main`, `beta`, `alpha`
- Uses Lerna for conventional commit versioning
- Publishes to GitHub Package Registry
- Explicitly ignores `aws-lambda-layer` in version calculations (`--ignore-changes aws-lambda-layer`)

### What Is Missing

| Gap | Description |
|-----|-------------|
| **No automation** | Layer is built manually via `npm run build` in `packages/aws-lambda-layer/` |
| **Hardcoded version** | `builder/index.js` has `sourcePackageVersion: '2.3.3'` — must be manually updated |
| **Stale registry config** | `src/index.js` still has GitLab registry URLs (lines 257-264) — not used by `builder/index.js` but would break if the library is called directly |
| **Stale package scope** | Builder references `@reventless/reventless-aws` but packages now publish under `@reventlessdev/*` |
| **No AWS publishing** | No automated publishing of the layer to AWS Lambda |
| **No version mapping** | No mechanism to look up which layer ARN corresponds to which `reventless-aws` version |
| **No multi-region** | Layer would need to be published to each AWS region separately |
| **Precompiled modules are static** | `@rescript/core@1.6.1` etc. are checked in — no process to update them when versions change |
| **Deprecated builder** | `builder/builder.js` (standalone, older version) still exists alongside `builder/index.js` (uses `src/index.js` library) |

---

## Proposal

### 1. Fix the Builder

Before automating, the builder needs these fixes:

**a) Update package scope:**
```javascript
// builder/index.js
sourcePackageName: '@reventlessdev/reventless-aws',
```

**b) Accept version from environment:**
```javascript
// builder/index.js
const version = process.env.REVENTLESS_AWS_VERSION || 'latest';
const opt = {
    sourcePackageName: '@reventlessdev/reventless-aws',
    sourcePackageVersion: version,
    // ...
};
```

**c) Fix registry config in `src/index.js`:**
Replace the hardcoded GitLab registry URLs (lines 256-264) with a `registryOpts` parameter passed from the caller:
```javascript
// src/index.js — build() function
export function build(opt) {
    const { sourcePackageName, sourcePackageVersion, pathToLayerData,
            pathToSavedDependencies, excludeScopes, excludeModules,
            postProcess, registryOpts = {} } = opt;
    // Use registryOpts instead of hardcoded GitLab URLs
    const opts = { ...registryOpts };
    // ...
}
```

```javascript
// builder/index.js — pass registry config
const opt = {
    // ...
    registryOpts: {
        "@reventlessdev:registry": "https://npm.pkg.github.com",
        "//npm.pkg.github.com/:_authToken": process.env.NODE_AUTH_TOKEN
    }
};
```

**d) Delete deprecated `builder/builder.js`** — it duplicates `src/index.js` logic and references old GitLab URLs.

**e) Update precompiled modules** — verify `@rescript/core`, `decco`, `bs-moment` versions match current dependency tree. Consider automating precompilation as a pre-build step.

### 2. GitHub Actions Workflow

Create `.github/workflows/build-lambda-layer.yml`:

```yaml
name: Build Lambda Layer

on:
  # Trigger when release workflow creates a reventless-aws tag
  push:
    tags:
      - '@reventlessdev/reventless-aws@*'

  # Allow manual builds for testing or rebuilds
  workflow_dispatch:
    inputs:
      version:
        description: 'reventless-aws version to build layer for'
        required: true

concurrency:
  group: lambda-layer
  cancel-in-progress: false

jobs:
  build-and-publish-layer:
    name: Build and Publish Lambda Layer
    runs-on: ubuntu-latest
    permissions:
      contents: write
      packages: read

    strategy:
      matrix:
        region: [eu-west-1]
        # Extend when needed:
        # region: [eu-west-1, us-east-1, eu-central-1]

    steps:
      - name: Checkout code
        uses: actions/checkout@v6

      - name: Setup Node.js
        uses: actions/setup-node@v6
        with:
          node-version: "22.17.1"
          registry-url: "https://npm.pkg.github.com"

      - name: Extract version
        id: version
        run: |
          if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
            VERSION="${{ inputs.version }}"
          else
            # Tag format: @reventlessdev/reventless-aws@3.0.0-alpha.9
            VERSION="${GITHUB_REF#refs/tags/@reventlessdev/reventless-aws@}"
          fi
          echo "version=$VERSION" >> $GITHUB_OUTPUT

      - name: Install layer builder dependencies
        working-directory: packages/aws-lambda-layer
        run: npm install
        env:
          NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Build Lambda layer
        working-directory: packages/aws-lambda-layer
        run: npm run build
        env:
          NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          REVENTLESS_AWS_VERSION: ${{ steps.version.outputs.version }}

      - name: Verify layer artifact
        working-directory: packages/aws-lambda-layer
        run: |
          if [ ! -f builder/reventless-layer.zip ]; then
            echo "Layer artifact not found"
            exit 1
          fi
          SIZE=$(du -h builder/reventless-layer.zip | cut -f1)
          echo "Layer artifact: $SIZE"

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_LAYER_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_LAYER_SECRET_ACCESS_KEY }}
          aws-region: ${{ matrix.region }}

      - name: Publish Lambda layer to AWS
        id: publish
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          REGION="${{ matrix.region }}"

          RESULT=$(aws lambda publish-layer-version \
            --layer-name reventless-aws \
            --description "reventless-aws@$VERSION" \
            --zip-file fileb://packages/aws-lambda-layer/builder/reventless-layer.zip \
            --compatible-runtimes nodejs20.x nodejs22.x \
            --compatible-architectures x86_64 arm64 \
            --region "$REGION" \
            --output json)

          LAYER_VERSION=$(echo "$RESULT" | jq -r '.Version')
          LAYER_ARN=$(echo "$RESULT" | jq -r '.LayerVersionArn')

          echo "layer_version=$LAYER_VERSION" >> $GITHUB_OUTPUT
          echo "layer_arn=$LAYER_ARN" >> $GITHUB_OUTPUT
          echo "Published layer version $LAYER_VERSION in $REGION"
          echo "ARN: $LAYER_ARN"

      - name: Upload layer artifact to release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          TAG="@reventlessdev/reventless-aws@$VERSION"
          REGION="${{ matrix.region }}"
          LAYER_ARN="${{ steps.publish.outputs.layer_arn }}"

          # Append layer info to the existing GitHub release
          EXISTING_BODY=$(gh release view "$TAG" --json body -q .body 2>/dev/null || echo "")
          NEW_BODY=$(printf '%s\n\n---\n\n**Lambda Layer ($REGION)**\n```\n%s\n```' "$EXISTING_BODY" "$LAYER_ARN")

          gh release edit "$TAG" --notes "$NEW_BODY" || echo "Could not update release notes"

          # Upload zip as release asset
          cp packages/aws-lambda-layer/builder/reventless-layer.zip \
             "reventless-layer-${VERSION}-${REGION}.zip"
          gh release upload "$TAG" "reventless-layer-${VERSION}-${REGION}.zip" \
             --clobber || echo "Could not upload asset"
```

**Key design decisions:**
- **Triggered by tag push** — the release workflow creates tags like `@reventlessdev/reventless-aws@3.0.0-alpha.9`, so this naturally chains after a release
- **Matrix strategy for regions** — start with one region, easily extend to multi-region
- **Separate AWS credentials** — uses dedicated `AWS_LAYER_*` secrets with minimal IAM permissions (only `lambda:PublishLayerVersion`)
- **Layer artifact attached to GitHub release** — the zip is uploaded as a release asset and the layer ARN is appended to release notes for discoverability

### 3. Application Configuration — Version Matching

The core question: how does an application know which layer ARN to use for its version of `reventless-aws`?

#### Option A: Pulumi Stack Config (Recommended)

Applications set the layer ARN in their Pulumi stack config:

```yaml
# Pulumi.prod.yaml
config:
  reventless:layerArn: "arn:aws:lambda:eu-west-1:123456789012:layer:reventless-aws:42"
```

The existing `REVENTLESS_LAYER_ARN` env var mechanism already supports this — set it in the Pulumi program:

```rescript
// In the application's deploy code
Pulumi.Config.make("reventless")
->Pulumi.Config.require("layerArn")
->Pulumi.Output.apply(arn => {
  NodeJs.Process.env->Dict.set("REVENTLESS_LAYER_ARN", arn)
})
```

**Pros:** Explicit, version-pinned, works with any region, supports different layers per stack (dev/staging/prod).
**Cons:** Manual update when upgrading `reventless-aws`.

#### Option B: Layer Version Manifest (Semi-Automated)

Publish a `layer-manifest.json` as a release artifact alongside `reventless-aws`:

```json
{
  "packageVersion": "3.0.0-alpha.9",
  "layers": {
    "eu-west-1": {
      "arn": "arn:aws:lambda:eu-west-1:123456789012:layer:reventless-aws:42",
      "version": 42
    }
  }
}
```

The CI workflow generates this after publishing and attaches it to the GitHub release. Applications can fetch it at deploy time:

```rescript
// Pseudocode — read manifest from GitHub release
let layerArn = LayerManifest.getArn(
  ~packageVersion=ReventlessAws.version,
  ~region=Pulumi.Aws.getRegion()
)
```

**Pros:** Automatic version matching, no manual ARN lookup.
**Cons:** Requires network access at deploy time, adds complexity.

#### Option C: Deterministic Layer Naming Convention

Use a naming convention that encodes the version:

```
Layer name: reventless-aws-3-0-0-alpha-9
```

Then the application can construct the ARN from the package version and AWS account/region:

```rescript
let layerName = "reventless-aws-" ++ version->String.replaceAll(".", "-")
// Construct or look up the ARN
```

**Pros:** No external lookup needed.
**Cons:** Lambda layer names can't contain `@` or `.`, so version encoding gets messy. Each version creates a new layer (not a new version of the same layer), harder to manage quotas.

#### Recommendation

**Use Option A (Pulumi Stack Config) as the primary mechanism.** It's the simplest, most reliable, and aligns with how Pulumi manages environment-specific config. When upgrading `reventless-aws`, look up the layer ARN from the GitHub release notes and update the stack config.

**Optionally add Option B (manifest)** later to reduce the manual step. The CI workflow would generate the manifest, and a helper function in `reventless-aws` could read it.

### 4. Required AWS Setup

#### IAM Policy

Create a dedicated IAM user or role for CI with minimal permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublishLambdaLayer",
      "Effect": "Allow",
      "Action": [
        "lambda:PublishLayerVersion",
        "lambda:GetLayerVersion"
      ],
      "Resource": "arn:aws:lambda:*:*:layer:reventless-aws*"
    }
  ]
}
```

#### GitHub Secrets

| Secret | Purpose |
|--------|---------|
| `AWS_LAYER_ACCESS_KEY_ID` | IAM access key for layer publishing |
| `AWS_LAYER_SECRET_ACCESS_KEY` | IAM secret key for layer publishing |

Using separate secrets (not shared with deploy credentials) limits blast radius if compromised.

### 5. Precompiled Modules Strategy

The checked-in precompiled modules (`@rescript/core`, `decco`, `bs-moment`) are a maintenance liability. When dependency versions change, they become stale.

**Short-term:** Document which versions are precompiled and add a check in the CI workflow that compares precompiled versions against the resolved dependency tree.

**Long-term:** Add a pre-build step that:
1. Installs `rescript` in a temporary directory
2. Compiles the ReScript packages that don't ship JS artifacts
3. Copies the compiled output to `builder/precompiled/`

This could be a `prebuild` npm script in `packages/aws-lambda-layer/package.json`.

---

## 6. Package Placement

The layer builder currently lives in `packages/aws-lambda-layer/`. With the planned ReScript migration and CI automation, the question is whether it should stay there, move, or be absorbed into another package.

### Current Monorepo Organization

| Folder | Purpose | Convention |
|--------|---------|------------|
| `reventless/` | Framework + extension packages | ReScript packages, published, runtime or deploy-time |
| `rescript/` | ReScript bindings for JS/npm libraries | Thin FFI wrappers, published, reusable |
| `examples/` | Example applications | Not published |
| `packages/` | Build tooling and documentation **only** | `doc`, `conventional-changelog-reventless`, `aws-lambda-layer` |

### Options

#### Option A: Stay in `packages/aws-lambda-layer/` (current)

Keep the package where it is, just migrate its internals to ReScript.

**Pros:**
- No directory moves, no git history disruption
- `packages/` is explicitly for build tooling — the layer builder is build tooling
- It's private (not published) — `packages/` is the natural home for private tooling
- The release workflow already has `--ignore-changes aws-lambda-layer` — no change needed

**Cons:**
- `packages/` currently has no ReScript packages — adding one breaks the implicit "JS/docs only" convention
- After ReScript migration, it needs `rescript.json` and must be included in the root `rescript.json` dependencies for compilation, which mixes build tooling into the framework dependency graph
- The name `aws-lambda-layer` doesn't follow the `reventless-*` naming pattern

#### Option B: Move to `reventless/reventless-layer-builder/`

Move the package into the `reventless/` workspace as a framework tool package.

**Pros:**
- Consistent with other ReScript packages — `reventless/` is where all ReScript packages live
- Follows `reventless-*` naming convention
- Natural fit in the root `rescript.json` dependencies alongside other `reventless-*` packages
- Could be published in the future if other projects need a layer builder
- Precedent: `reventless-gen` is already a build-time tool (Plop scaffolding) living in `reventless/`, not `packages/`

**Cons:**
- Git history disruption from the move (mitigated by `git mv`)
- Need to update `--ignore-changes` in release workflow from `aws-lambda-layer` to the new path
- Slightly blurs the line between "framework runtime" and "framework tooling" in `reventless/`

#### Option C: Integrate into `reventless/reventless-aws/`

Merge the layer builder into the `reventless-aws` package itself, since it builds layers specifically for that package.

**Pros:**
- Co-location — the builder lives next to what it builds
- Version stays in sync automatically (same package, same version)
- No separate package to maintain

**Cons:**
- **Adds heavy build-time dependencies** (`@npmcli/arborist`, `pacote`, `treeverse`, `rimraf`, `zip-a-folder`) to a runtime package — these would be installed by every application that depends on `reventless-aws`
- Breaks the separation between runtime code and build tooling
- `reventless-aws` is a published, non-private package — the builder is private tooling
- The `precompiled/` directory and `layer/` output directory would clutter the package
- Fundamentally different concern: `reventless-aws` = "how to run on AWS", layer builder = "how to package for AWS"

#### Option D: Split into generic bindings + Reventless-specific builder

Create `rescript/rescript-npmcli-arborist/` (bindings) and `reventless/reventless-layer-builder/` (logic).

**Pros:**
- Follows the repo convention of separating bindings (`rescript/*`) from framework code (`reventless/*`)
- Arborist/pacote/treeverse bindings could theoretically be reused

**Cons:**
- Over-engineering — these npm libraries have no TypeScript types, the bindings are minimal and purpose-built, and there's no realistic reuse case
- Two packages instead of one for a single tool
- More maintenance overhead for no benefit

### Recommendation: Option B — `reventless/reventless-layer-builder/`

**Move the package to `reventless/reventless-layer-builder/`.**

Rationale:

1. **Precedent**: `reventless-gen` already lives in `reventless/` as a build-time tool. The layer builder is the same category — framework tooling that isn't runtime code but is part of the framework ecosystem.

2. **ReScript compilation**: After migration, the package must be in the root `rescript.json` dependency graph. All other packages in that graph live in `reventless/` or `rescript/`. Having one outlier in `packages/` is confusing.

3. **Naming**: `reventless-layer-builder` clearly communicates what it does and follows the `reventless-*` convention. The current `aws-lambda-layer` name is vague and doesn't indicate it's Reventless-specific.

4. **Bindings co-located**: The Arborist/pacote/treeverse bindings stay inside this package (not split into separate `rescript/*` packages) because they're purpose-built, untyped upstream, and have no reuse case.

5. **Private**: The package stays private (`"private": true`) — it's never published to the registry. This is fine in `reventless/`; `reventless-gen` could also be private if needed.

### Migration Path

```bash
# 1. Move the package
git mv packages/aws-lambda-layer reventless/reventless-layer-builder

# 2. Update package.json
#    - name: "aws-lambda-layer" → "@reventlessdev/reventless-layer-builder"
#    - bugs.url: update to GitHub

# 3. Update release workflow
#    - --ignore-changes aws-lambda-layer → --ignore-changes reventless-layer-builder

# 4. Update root rescript.json (after ReScript migration)
#    - Add "@reventlessdev/reventless-layer-builder" to dependencies

# 5. Update CI workflow
#    - working-directory: packages/aws-lambda-layer → reventless/reventless-layer-builder
```

### Final Package Structure (after move + ReScript migration)

```
reventless/reventless-layer-builder/
  package.json                      # @reventlessdev/reventless-layer-builder (private)
  rescript.json
  src/
    LambdaLayerBuilder.res          # Main build orchestration
    LambdaLayerBuilder_Config.res   # Configuration types
    LambdaLayerBuilder_Filter.res   # Dependency filtering logic
    LambdaLayerBuilder_Stats.res    # Tree statistics
    LambdaLayerBuilder_PostProcess.res  # Post-processing hooks
    bindings/
      Arborist.res                  # @npmcli/arborist bindings
      Pacote.res                    # pacote bindings
      Treeverse.res                 # treeverse bindings
      Rimraf.res                    # rimraf bindings
      ZipAFolder.res                # zip-a-folder bindings
      NodePath.res                  # node:path bindings
      NodeFs.res                    # node:fs bindings (partial)
  builder/
    Main.res                        # Entry point with Reventless-specific config
    precompiled/                    # Pre-built ReScript modules
    layer/                          # Output directory (gitignored)
```

---

## 7. Migration from JavaScript to ReScript

The layer builder is currently pure JavaScript (`src/index.js`, `builder/index.js`, `builder/postprocess.js`). Migrating it to ReScript aligns with the rest of the codebase and brings type safety to a build-critical tool that currently has no type checking.

### Current JavaScript Code Inventory

| File | Lines | Purpose |
|------|-------|---------|
| `src/index.js` | 423 | Generic layer builder library — Arborist tree resolution, dependency filtering, extraction, zipping |
| `builder/index.js` | 31 | Entry point — Reventless-specific configuration |
| `builder/postprocess.js` | 73 | Post-processing hooks — file cleanup, precompiled module copying |
| `builder/builder.js` | ~350 | **Deprecated** standalone builder (delete before migration) |
| **Total (active)** | **~527** | |

### External Dependencies Requiring Bindings

The builder uses three npm libraries that have **no TypeScript type definitions**:

#### `@npmcli/arborist` — Dependency Tree Management

The most complex binding. Arborist creates a tree of `Node` objects with `Map`-based children and edge collections.

```rescript
// Arborist.res — bindings for @npmcli/arborist

module Node = {
  type t

  @get external name: t => string = "name"
  @get external version: t => string = "version"
  @get external packageName: t => string = "packageName"
  @get external path: t => string = "path"
  @get external location: t => string = "location"
  @get external resolved: t => Nullable.t<string> = "resolved"
  @get external isRoot: t => bool = "isRoot"

  // Dependency classification flags
  @get external dev: t => bool = "dev"
  @get external optional: t => bool = "optional"
  @get external devOptional: t => bool = "devOptional"
  @get external peer: t => bool = "peer"

  // Children is a JS Map<string, Node>
  @get external children: t => Map.t<string, t> = "children"

  // Edges
  @get external edgesOut: t => Map.t<string, Edge.t> = "edgesOut"
  @get external edgesIn: t => Set.t<Edge.t> = "edgesIn"
}

module Edge = {
  type t

  @get external name: t => string = "name"
  @get external type_: t => string = "type"
  @get external from: t => Node.t = "from"
  @get external to: t => Nullable.t<Node.t> = "to"
  @get external prod: t => bool = "prod"
}

type buildIdealTreeOpts = {
  preferDedupe?: bool,
  saveType?: string,
}

type t

@new @module("@npmcli/arborist")
external make: {..} => t = "default"

@send
external buildIdealTree: (t, buildIdealTreeOpts) => promise<Node.t> = "buildIdealTree"
```

**Challenge: JavaScript `Map` and `Set`.** Arborist uses native JS `Map<string, Node>` for `children` and `edgesOut`, and `Set<Edge>` for `edgesIn`. ReScript's `Map` module (from `RescriptCore`) provides bindings for JS `Map`, so this works directly. The key operations needed:

```rescript
// Iterating children
node->Node.children->Map.forEach((child, key) => { ... })

// Getting size
node->Node.children->Map.size

// Deleting
node->Node.children->Map.delete(key)

// Converting to array
node->Node.edgesIn->Set.values->Iterator.toArray
```

#### `pacote` — Package Extraction

Simple binding — only one function is used:

```rescript
// Pacote.res

@module("pacote")
external extract: (string, string, {..}) => promise<unit> = "extract"
```

#### `treeverse` — Tree Traversal

Used for depth-first traversal of the Arborist tree:

```rescript
// Treeverse.res

type depthOpts<'node, 'result> = {
  tree: 'node,
  visit: 'node => option<promise<'result>>,
  getChildren: 'node => array<'node>,
  filter?: 'node => bool,
}

@module("treeverse")
external depth: depthOpts<'node, 'result> => promise<'result> = "depth"
```

**Challenge: Polymorphic callback signatures.** The `visit` callback in the current JS code returns either `undefined` (skip), a `Promise` (extract), or nothing. In ReScript this maps naturally to `option<promise<'result>>`. The `getChildren` callback in `treeverse.depth` also receives the result of `visit` as a second argument — this requires careful typing or use of `Obj.magic` for the untyped second parameter.

#### Standard Node.js APIs

Several Node.js APIs are used but have no existing bindings in the repo:

```rescript
// NodePath.res
@module("node:path")
external resolve: (string, string) => string = "resolve"

@module("node:path")
external join: (string, string) => string = "join"

@module("node:path")
external dirname: string => string = "dirname"

// NodeFs.res (partial — only what's needed)
@module("node:fs")
external existsSync: string => bool = "existsSync"

@module("node:fs")
external cp: (string, string, {"recursive": bool}, option<Exn.t> => unit) => unit = "cp"
```

`rimraf` and `zip-a-folder` are straightforward:

```rescript
// Rimraf.res
@module("rimraf")
external rimraf: (string, {"glob": {"cwd": string}}) => promise<unit> = "rimraf"

@module("rimraf")
external rimrafMany: (array<string>) => promise<unit> = "rimraf"

// ZipAFolder.res
@module("zip-a-folder")
external zip: (string, string) => promise<unit> = "zip"
```

`ora` and `debug` are CLI progress/logging — bindings are optional (could use `Console.log` instead, or create minimal bindings).

### Package Structure

The migrated package lives in `reventless/reventless-layer-builder/` as proposed in section 6. The bindings are co-located (not split into separate `rescript/*` packages) since they're purpose-built and the underlying libraries have no TypeScript types. See section 6 for the full directory structure.

### Migration Strategy

#### Phase 1: Bindings Only (Low Risk)

Create ReScript binding files for the external dependencies while keeping the existing JS implementation working. This validates the type mappings without changing behavior.

1. Create `rescript.json` and `package.json` for the new package
2. Write binding files: `Arborist.res`, `Pacote.res`, `Treeverse.res`, `Rimraf.res`, `ZipAFolder.res`
3. Write a small test that exercises each binding (create Arborist, build tree, extract a package)
4. Verify the compiled `.res.mjs` output works

#### Phase 2: Core Logic

Migrate the pure logic functions that don't depend on external state:

1. **`LambdaLayerBuilder_Filter.res`** — `predIsNecessary`, `isNodeScopeExcluded`, `isNodeExcluded`, `isNodeProd`, `hasDependency`. These are pure predicate functions that translate directly to ReScript pattern matching:

```rescript
type filterReason =
  | Dev
  | Optional
  | DevOptional
  | Peer
  | ScopeExcluded(string)
  | ModuleExcluded
  | DependentExcluded

let isNecessary = (~excludedScopes, ~excludedModules, node: Arborist.Node.t) => {
  let name = node->Arborist.Node.name
  if node->Arborist.Node.dev {
    Error(Dev)
  } else if node->Arborist.Node.optional {
    Error(Optional)
  } else if node->Arborist.Node.devOptional {
    Error(DevOptional)
  } else if node->Arborist.Node.peer {
    Error(Peer)
  } else if excludedScopes->Array.some(scope => name->String.startsWith(`@${scope}/`)) {
    Error(ScopeExcluded(name))
  } else if excludedModules->Array.includes(name) {
    Error(ModuleExcluded)
  } else {
    // Transitive dependency check via treeverse depth traversal
    // ...
    Ok()
  }
}
```

2. **`LambdaLayerBuilder_Stats.res`** — `maxDepth`, `countChildrenRecursive`, `hasChildren`. Pure recursive functions over the `Node` tree.

3. **`LambdaLayerBuilder_PostProcess.res`** — Post-processing hooks. These are async functions calling `rimraf` and `cp`:

```rescript
let rescriptDependent = async (_node, cwd) => {
  let _ = await Rimraf.rimraf("**/*.res", ~glob={cwd: cwd})
  let _ = await Rimraf.rimraf("**/*.resi", ~glob={cwd: cwd})
}

let moment = async (_node, cwd) => {
  let _ = await Rimraf.rimrafMany([
    NodePath.resolve(cwd, "min"),
    NodePath.resolve(cwd, "src"),
    NodePath.resolve(cwd, "dist"),
  ])
}
```

#### Phase 3: Build Orchestration

Migrate the main `build()` function — the async pipeline that chains extraction, filtering, post-processing, and zipping:

```rescript
// LambdaLayerBuilder.res

let build = async (config: LambdaLayerBuilder_Config.t) => {
  // Phase 1: Extract source package
  let rootPath = NodePath.resolve(config.pathToSavedDependencies, config.sourcePackageName)
  let sourceSpec = `${config.sourcePackageName}@${config.sourcePackageVersion}`
  let _ = await Pacote.extract(sourceSpec, rootPath, config.registryOpts)

  // Phase 2: Build ideal dependency tree
  let arb = Arborist.make({"path": rootPath, ...config.registryOpts})
  let tree = await arb->Arborist.buildIdealTree({preferDedupe: true, saveType: "prod"})

  // Phase 3: Filter and extract dependencies
  let _ = await Treeverse.depth({
    tree,
    visit: node => {
      if node->Arborist.Node.isRoot {
        None
      } else {
        switch LambdaLayerBuilder_Filter.isNecessary(
          ~excludedScopes=config.excludeScopes,
          ~excludedModules=config.excludeModules,
          node
        ) {
        | Ok() => Some(extractAndPostProcess(node, config))
        | Error(reason) =>
          Console.log(`Skipping ${node->Arborist.Node.name}: ${reason->filterReasonToString}`)
          None
        }
      }
    },
    getChildren: node =>
      node->Arborist.Node.children->Map.values->Iterator.toArray,
  })

  // Phase 4: Zip
  let _ = await ZipAFolder.zip(config.pathToLayerData, NodePath.join(config.pathToLayerData, "../reventless-layer.zip"))
}
```

#### Phase 4: Entry Point

Replace `builder/index.js` with `builder/Main.res`:

```rescript
// builder/Main.res

@val external version: option<string> = "process.env.REVENTLESS_AWS_VERSION"
@val external authToken: option<string> = "process.env.NODE_AUTH_TOKEN"

let config: LambdaLayerBuilder_Config.t = {
  sourcePackageName: "@reventlessdev/reventless-aws",
  sourcePackageVersion: version->Option.getOr("latest"),
  pathToLayerData: NodePath.resolve(NodeProcess.cwd(), "builder/layer"),
  pathToSavedDependencies: NodePath.resolve(NodeProcess.cwd(), "builder/layer/nodejs/node_modules"),
  excludeScopes: ["pulumi", "types", "opentelemetry"],
  excludeModules: ["aws-sdk"],
  registryOpts: {
    "@reventlessdev:registry": "https://npm.pkg.github.com",
    "//npm.pkg.github.com/:_authToken": authToken->Option.getOr(""),
  },
  postProcess: [
    PackageHook("@rescript-labs/decco", LambdaLayerBuilder_PostProcess.decco),
    PackageHook("@reventless/reventless", LambdaLayerBuilder_PostProcess.reventless),
    DependencyHook("rescript", LambdaLayerBuilder_PostProcess.rescriptDependent),
    DependencyHook("bs-platform", LambdaLayerBuilder_PostProcess.bsPlatformDependent),
    PackageHook("object-assign", LambdaLayerBuilder_PostProcess.objectAssign),
    PackageHook("moment", LambdaLayerBuilder_PostProcess.moment),
    PackageHook("bs-moment", LambdaLayerBuilder_PostProcess.bsMoment),
    PackageHook("@rescript/core", LambdaLayerBuilder_PostProcess.rescriptCore),
  ],
}

let _ = LambdaLayerBuilder.build(config)
```

### Key Challenges

#### 1. No TypeScript Types for npm Tooling

`@npmcli/arborist`, `pacote`, and `treeverse` ship no `.d.ts` files and no `@types/*` packages exist. Bindings must be created from JSDoc comments and runtime inspection. This means:
- Initial bindings may be incomplete — type only what's actually used
- Runtime behavior must be verified through testing
- The `{..}` open object type can be used as an escape hatch for option bags

#### 2. JavaScript `Map` Iteration with Side Effects

The current JS code mutates Maps during iteration (e.g., `map.delete(key)` inside `forEach`). ReScript's `Map` bindings support this but it's an imperative pattern. The filtering logic should be restructured:

```rescript
// Instead of mutating during iteration, collect keys to delete, then delete
let keysToDelete = []
node->Arborist.Node.children->Map.forEach((child, key) => {
  if !isNecessary(child) {
    keysToDelete->Array.push(key)
  }
})
keysToDelete->Array.forEach(key => {
  node->Arborist.Node.children->Map.delete(key)->ignore
})
```

#### 3. Promise Chaining with Mutable State

The current `build()` function uses `.then()` chains with mutable variables captured in closure (`rescriptModule`, `extractionCount`, etc.). In ReScript, this translates naturally to `async/await` with `ref` values:

```rescript
let rescriptModule = ref(None)
let extractionCount = ref(0)

// Inside the traversal:
rescriptModule := Some(node)
extractionCount := extractionCount.contents + 1
```

#### 4. Post-Processing Hook Dictionary

The current JS code uses a plain object as a dictionary with special `>prefix` keys for dependency-based hooks. In ReScript, model this as a variant:

```rescript
type postProcessHook =
  | PackageHook(string, (Arborist.Node.t, string) => promise<unit>)
  | DependencyHook(string, (Arborist.Node.t, string) => promise<unit>)
```

#### 5. CLI Output (ora/debug)

The `ora` spinner and `debug` logger are optional for correctness. Options:
- **Minimal approach:** Replace with `Console.log` / `Console.error` — simplest, works in CI
- **Bind ora/debug:** Create small bindings if the interactive CLI experience is desired for local builds

### Benefits of Migration

| Benefit | Impact |
|---------|--------|
| **Type safety on Arborist Node properties** | Catch `node.dev` vs `node.optional` confusion at compile time |
| **Exhaustive pattern matching on filter reasons** | No more silent fallthrough in `predIsNecessary` |
| **Consistent codebase** | All framework tooling in ReScript — one language to maintain |
| **Better refactoring** | Compiler catches breakage when Arborist API changes |
| **Immutable-first logic** | Cleaner dependency filtering without mutation-during-iteration bugs |
| **Eliminates deprecated code** | Migration naturally removes `builder.js` and stale GitLab config |

### Risks

| Risk | Mitigation |
|------|------------|
| **Arborist API surface is large, untyped** | Only bind what's used; use `{..}` open objects for option bags |
| **Build tooling requires itself to compile** | The layer builder runs on Node.js directly; ensure `rescript build` runs before `npm run build` in the layer package |
| **Behavioral differences in compiled output** | Run the existing JS builder and new ReScript builder side-by-side, compare output zips |
| **CI needs ReScript compiler** | Already available in the monorepo — `npm run build` from root compiles all packages |

### Recommended Sequencing

The ReScript migration should happen **after** the automation (sections 1-5) and the package move (section 6) are in place, not before. Rationale:

1. Automation is the primary goal and delivers value immediately
2. The existing JS code works — migration is a quality improvement, not a fix
3. Having CI automation first means the migration can be validated by running the automated pipeline
4. Migration phases can be done incrementally — each phase can be merged and tested via the automated layer build

**Order of work:**
1. Fix builder (section 1) and set up CI (section 2) — delivers automation
2. Move package to `reventless/reventless-layer-builder/` (section 6)
3. Phase 1: Create bindings, validate with tests
4. Phase 2: Migrate filter/stats logic
5. Phase 3: Migrate build orchestration
6. Phase 4: Migrate entry point, delete old JS files

---

## 8. Cross-Cloud Analysis: Generalizing Beyond AWS Lambda Layers

If Reventless were to support additional cloud providers (e.g., a `reventless-azure` or `reventless-gcp` package), would the same "pre-packaged dependency bundle" pattern apply? This section analyzes equivalents on Azure and GCP and evaluates whether a generic approach is viable.

### Equivalent Concepts by Provider

#### AWS Lambda — Lambda Layers

- **Mechanism**: Upload a zip containing `nodejs/node_modules/`. Attached to functions via layer ARN. Contents extracted to `/opt/` at runtime, automatically added to Node.js module resolution path.
- **Key property**: A layer is a **separate, versioned artifact** managed independently from the function code. Multiple functions share the same layer.
- **Size limit**: 50 MB (zipped), 250 MB (unzipped, combined with function code).
- **Management**: `aws lambda publish-layer-version` creates an immutable, versioned layer. ARN includes version number.

#### Azure Functions — No Direct Equivalent

Azure Functions has **no Lambda Layers equivalent**. Dependencies are deployed as part of the function app package itself.

**How Azure handles dependencies:**
- **Zip deployment**: The entire function app (code + `node_modules/`) is zipped and deployed as one unit. Setting `WEBSITE_RUN_FROM_PACKAGE=1` runs directly from the zip.
- **Remote build**: If `SCM_DO_BUILD_DURING_DEPLOYMENT=true`, Azure runs `npm install` during deployment — but this is slow and unreliable for private registries.
- **Extension bundles**: Azure's "extension bundles" are for C# binding extensions, not for sharing Node.js dependencies across functions.

**The closest Azure equivalent** is a **pre-built deployment package**: a zip containing all application code plus a pre-populated `node_modules/` directory. This is conceptually identical to what the layer builder produces — the difference is that on Azure, there's no separation between "framework dependencies" and "application code". They ship as one package.

**What the builder would produce for Azure:** A pre-built `node_modules/` directory (not zipped as a layer, but included in each function app's deployment package). Or, a **base Docker image** with dependencies pre-installed, used by Azure Functions running in a custom container.

#### GCP Cloud Run Functions — No Direct Equivalent

GCP Cloud Functions (now Cloud Run Functions) also has **no Lambda Layers equivalent**.

**How GCP handles dependencies:**
- **Automatic dependency installation**: List dependencies in `package.json`, and GCP's buildpacks run `npm install` during the build phase. This is the default — no manual packaging needed.
- **Vendored dependencies**: Set `GOOGLE_VENDOR_NPM_DEPENDENCIES=true` and include `node_modules/` in the deployment. GCP skips `npm install` and uses the pre-installed modules.
- **Private packages via Artifact Registry**: GCP supports `.npmrc` authentication against Google Artifact Registry for private npm packages. The build system fetches them automatically.
- **Custom container images**: For Cloud Run (not Cloud Run Functions), you can build a Docker image with all dependencies baked in, then deploy the container.

**The closest GCP equivalent** is **vendored node_modules** or a **custom container base image**. Like Azure, there's no separate "layer" artifact — dependencies are part of the deployment unit.

### Comparison Matrix

| Aspect | AWS Lambda | Azure Functions | GCP Cloud Run Functions |
|--------|-----------|----------------|------------------------|
| **Separate dependency layer** | Yes (Lambda Layers) | No | No |
| **Pre-built node_modules in deploy package** | Optional (via layer) | Yes (primary approach) | Yes (vendored deps) |
| **Custom container with pre-installed deps** | Yes (container image) | Yes (custom containers) | Yes (Cloud Run) |
| **Automatic npm install at build time** | No | Optional (SCM_DO_BUILD) | Yes (default) |
| **Artifact versioning** | Layer version ARN | Deployment slot / zip hash | Container image tag |
| **Shared across functions** | Yes (same layer ARN) | No (per-app package) | No (per-function build) |

### Is a Generic Approach Viable?

The layer builder already has a two-part architecture: a **generic library** (`src/index.js`) that resolves, filters, and extracts dependencies, and a **provider-specific builder** (`builder/index.js`) that configures it for Reventless.

The generic library's output — a filtered, optimized `node_modules/` directory — is useful for **all three providers**. What differs is only the **packaging and publishing step**:

| Step | AWS | Azure | GCP |
|------|-----|-------|-----|
| 1. Resolve dependency tree | Same | Same | Same |
| 2. Filter dependencies | Same | Same | Same |
| 3. Extract + post-process | Same | Same | Same |
| 4. **Package** | Zip as `nodejs/node_modules/` | Zip as part of app package, OR Docker image | Vendored `node_modules/`, OR Docker image |
| 5. **Publish** | `aws lambda publish-layer-version` | Deploy to Azure, OR push to ACR | Deploy to GCP, OR push to Artifact Registry |

Steps 1-3 are **provider-agnostic** and already separated in the current architecture. Step 4-5 is where provider-specific logic lives.

### Proposed Generic Architecture

Extend the builder with a **pluggable packaging/publishing backend**:

```
reventless/reventless-layer-builder/
  src/
    # Provider-agnostic core (already exists)
    LambdaLayerBuilder.res            # Rename to DependencyBundler.res
    LambdaLayerBuilder_Config.res     # Generic config types
    LambdaLayerBuilder_Filter.res     # Dependency filtering
    LambdaLayerBuilder_PostProcess.res

    # Provider-specific packaging
    packaging/
      Packaging.res                   # Module type for packaging backends
      Packaging_AwsLambdaLayer.res    # Zip as nodejs/node_modules/ + publish via AWS CLI
      Packaging_Docker.res            # Build Docker image with node_modules baked in
      Packaging_VendoredModules.res   # Output raw node_modules/ for vendored deploy
```

The module type for packaging backends:

```rescript
// Packaging.res
module type T = {
  type config
  type publishResult

  /** Package the built node_modules directory into provider-specific format */
  let package: (~nodeModulesPath: string, ~outputPath: string, ~config: config) => promise<string>

  /** Publish the packaged artifact to the cloud provider */
  let publish: (~artifactPath: string, ~version: string, ~config: config) => promise<publishResult>
}
```

Implementations:

```rescript
// Packaging_AwsLambdaLayer.res
module Make: Packaging.T = {
  type config = { layerName: string, regions: array<string> }
  type publishResult = { arn: string, version: int }

  let package = async (~nodeModulesPath, ~outputPath, ~config as _) => {
    // Wrap in nodejs/node_modules/ structure, zip
    ...
  }

  let publish = async (~artifactPath, ~version, ~config) => {
    // aws lambda publish-layer-version
    ...
  }
}

// Packaging_Docker.res
module Make: Packaging.T = {
  type config = { baseImage: string, registry: string, imageName: string }
  type publishResult = { imageUri: string, digest: string }

  let package = async (~nodeModulesPath, ~outputPath, ~config) => {
    // Generate Dockerfile, build image
    ...
  }

  let publish = async (~artifactPath, ~version, ~config) => {
    // docker push to registry (ACR, Artifact Registry, ECR)
    ...
  }
}
```

### Effort Assessment

| Work Item | Effort | When |
|-----------|--------|------|
| **Refactor core into provider-agnostic DependencyBundler** | Low | During ReScript migration (section 7, phase 3). The separation already exists in the JS code — just formalize it. |
| **AWS Lambda Layer packaging backend** | Low | Extract existing zip + publish logic into `Packaging_AwsLambdaLayer`. Already written. |
| **Docker image packaging backend** | Medium | Write Dockerfile generation + `docker build` + `docker push` orchestration. Useful for both Azure custom containers and GCP Cloud Run. |
| **Vendored modules packaging backend** | Low | Simply copy `node_modules/` to output — essentially a no-op compared to the full build. Useful for GCP's `GOOGLE_VENDOR_NPM_DEPENDENCIES` pattern. |
| **Azure-specific CI workflow** | Medium | Azure CLI calls, Azure Container Registry push, Function App deployment. Different auth model (service principals vs IAM keys). |
| **GCP-specific CI workflow** | Medium | gcloud CLI, Artifact Registry push. Different auth model (workload identity federation). |
| **`reventless-azure` package** | **Large** | Does not exist yet. This is the real bottleneck — the layer builder generalization is pointless without a provider package to build layers for. |
| **`reventless-gcp` package** | **Large** | Does not exist yet. Same situation. |

### Recommendation

**Do not generalize prematurely.** The effort breaks down as:

1. **Making the core provider-agnostic: Low effort, do it during the ReScript migration.** Simply name things generically (`DependencyBundler` instead of `LambdaLayerBuilder`) and keep the AWS-specific packaging as one implementation of a module type. This costs almost nothing extra and keeps the door open.

2. **Building Azure/GCP packaging backends: Medium effort each, but only valuable when `reventless-azure` or `reventless-gcp` exist.** These provider packages are the prerequisite — without them, there's nothing to build a dependency bundle for.

3. **The Docker image backend is the most portable.** If Azure or GCP support materializes, a single Docker-based packaging backend works for both (Azure custom containers + GCP Cloud Run). This is the first backend to add after the AWS Lambda Layer one.

**Concrete actions:**

- **Now**: Build the AWS Lambda Layer automation as designed (sections 1-5).
- **During ReScript migration**: Use generic names (`DependencyBundler`, `Packaging.T` module type) so the architecture supports future backends without refactoring. Extract the AWS-specific zip+publish into `Packaging_AwsLambdaLayer`.
- **When a second provider package exists**: Add `Packaging_Docker` as the cross-cloud backend and the provider-specific CI workflow.

---

## Summary of Changes Needed

### Immediate (to enable automation)

1. **Fix `builder/index.js`** — update package scope to `@reventlessdev`, read version from `REVENTLESS_AWS_VERSION` env var
2. **Fix `src/index.js`** — accept `registryOpts` parameter instead of hardcoded GitLab URLs
3. **Delete `builder/builder.js`** — deprecated standalone builder
4. **Create `.github/workflows/build-lambda-layer.yml`** — automated build + AWS publish
5. **Set up AWS IAM user** and add `AWS_LAYER_*` secrets to GitHub repo

### Package move

6. **Move `packages/aws-lambda-layer/` to `reventless/reventless-layer-builder/`** — rename package to `@reventlessdev/reventless-layer-builder`, update release workflow `--ignore-changes`, update CI workflow paths

### Application-side

7. **Document Pulumi stack config pattern** for setting `REVENTLESS_LAYER_ARN` — add to `packages/doc/docs/` deployment guide

### ReScript migration (after automation + move are in place)

8. **Phase 1**: Create ReScript bindings for `@npmcli/arborist`, `pacote`, `treeverse`, `rimraf`, `zip-a-folder`
9. **Phase 2**: Migrate filter logic (`predIsNecessary`) and stats functions to ReScript
10. **Phase 3**: Migrate build orchestration to ReScript — use generic names (`DependencyBundler`, `Packaging.T` module type) to keep architecture extensible for future cloud providers
11. **Phase 4**: Migrate entry point, extract AWS-specific packaging into `Packaging_AwsLambdaLayer`, delete old JS files

### Future improvements

12. Layer version manifest (Option B) for semi-automated version matching
13. Automated precompiled module rebuilding
14. Multi-region publishing (extend matrix in workflow)
15. Layer size monitoring / alerts (warn if layer exceeds 40MB approaching the 50MB limit)
16. `Packaging_Docker` backend — builds a container image with pre-installed `node_modules/`, usable for Azure custom containers and GCP Cloud Run (only when a second provider package exists)
