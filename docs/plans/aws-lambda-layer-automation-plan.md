# Plan: Automated AWS Lambda Layer Creation

**Analysis**: [docs/analysis/done/aws-lambda-layer-automation.md](../analysis/done/aws-lambda-layer-automation.md)

## Overview

Automate Lambda layer creation every time `@reventlessdev/reventless-aws` is released. Move and rename the builder package. Migrate it to ReScript. Prepare the architecture for future cloud providers.

---

## Step 1: Fix the Builder (JS-only, no move yet)

Fix the existing `packages/aws-lambda-layer/` so it works correctly with the current GitHub registry and can accept the version from the environment.

- [x] Update `builder/index.js`: change `sourcePackageName` from `@reventless/reventless-aws` to `@reventlessdev/reventless-aws`
- [x] Update `builder/index.js`: read version from `process.env.REVENTLESS_AWS_VERSION` with fallback to `'latest'` (remove hardcoded `'2.3.3'`)
- [x] Update `src/index.js`: replace hardcoded GitLab registry URLs (lines 256-264) with a `registryOpts` parameter passed from the caller
- [x] Update `builder/index.js`: pass `registryOpts` with GitHub Package Registry config (`@reventlessdev:registry`, `//npm.pkg.github.com/:_authToken`)
- [x] Delete deprecated `builder/builder.js`
- [x] Update `package.json`: fix `bugs.url` from GitLab to GitHub
- [x] ~~Verify precompiled module versions~~ — removed stale precompiled directory (decco, bs-moment, @rescript/core no longer in dependency tree)
- [x] Test locally: `REVENTLESS_AWS_VERSION=3.0.0-alpha.9 npm run build`

Additional fixes applied during Step 1:
- [x] Add cleanup step (`rimraf`) at start of build to prevent stale leftovers
- [x] Add `sury-ppx` to `excludeModules` (93 MB build-time PPX binary)
- [x] Add `smithy`, `sigstore` to `excludeScopes`
- [x] Add postprocess for `effect` (delete `src/`), `reventless-core` (delete tests/scripts), `rescript-effect` (delete tests)
- [x] Remove stale postprocess entries (decco, moment, bs-moment, object-assign, bs-platform, @rescript/core)
- [x] Delete `builder/precompiled/` directory
- [x] Downgrade `ora` from v9 to v6 (npm workspace hoisting fix)
- [x] Remove unused `pino`/`pino-pretty` dependencies

## Step 2: Create GitHub Actions Workflow

Create `.github/workflows/build-lambda-layer.yml` that triggers on `@reventlessdev/reventless-aws@*` tag pushes.

- [x] Create workflow file triggered by tag push (`@reventlessdev/reventless-aws@*`) and `workflow_dispatch`
- [x] Extract version from tag or manual input
- [x] Install dependencies, build layer, verify artifact exists
- [x] Configure AWS credentials (`AWS_LAYER_ACCESS_KEY_ID`, `AWS_LAYER_SECRET_ACCESS_KEY` secrets)
- [x] Publish layer via `aws lambda publish-layer-version` (start with `eu-west-1`, use matrix for future regions)
- [x] Upload zip as GitHub release asset and append layer ARN to release notes
- [x] Test with `workflow_dispatch` before relying on tag triggers

## Step 3: AWS IAM Setup

Create a dedicated IAM user/role with minimal permissions for CI layer publishing.

- [x] Create IAM policy with only `lambda:PublishLayerVersion` and `lambda:GetLayerVersion` on `arn:aws:lambda:*:*:layer:reventless-aws*`
- [x] Create IAM user `reventless-ci-layer-publisher` for CI
- [x] Add `AWS_LAYER_ACCESS_KEY_ID` and `AWS_LAYER_SECRET_ACCESS_KEY` to GitHub repo secrets

## Step 4: Document Application Configuration

Document how applications use the layer via Pulumi stack config.

- [x] Add deployment guide section to `packages/doc/docs/` explaining `REVENTLESS_LAYER_ARN` env var
- [x] Document Pulumi stack config pattern: `reventless:layerArn` in `Pulumi.<stack>.yaml`
- [x] Document how to find the correct layer ARN from GitHub release notes

## Step 5: Move Package

Move `packages/aws-lambda-layer/` to `reventless/reventless-layer-builder/`.

- [x] `git mv packages/aws-lambda-layer reventless/reventless-layer-builder`
- [x] Update `package.json`: rename to `@reventlessdev/reventless-layer-builder`, keep `"private": true`
- [x] Update `.github/workflows/release.yml`: change `--ignore-changes aws-lambda-layer` to `--ignore-changes reventless-layer-builder`
- [x] Update `.github/workflows/build-lambda-layer.yml`: change `working-directory` paths
- [x] Update `CLAUDE.md`: move package from `packages/` to `reventless/` section
- [x] Verify `npm install` and `npm run build` still work from new location
- [x] Verify CI workflow triggers correctly (March 8 succeeded; March 17 failure is GitHub token permissions issue unrelated to package move)

## Step 6: ReScript Migration — Phase 1: Bindings

Create ReScript bindings for all external dependencies while keeping the JS implementation working.

- [x] Add `rescript.json` to `reventless/reventless-layer-builder/`
- [x] Add `rescript` as dev dependency in `package.json` (`@rescript/core` provided via `rescript` transitive dep)
- [x] Create `src/bindings/Arborist.res` — bindings for `@npmcli/arborist` (`node`, `edge`, constructor, `buildIdealTree`, Map/Set helpers)
- [x] Create `src/bindings/Pacote.res` — binding for `pacote.extract`
- [x] Create `src/bindings/Treeverse.res` — binding for `treeverse.depth` (polymorphic sync/async)
- [x] Create `src/bindings/Rimraf.res` — bindings for `rimraf` (single path, glob pattern, array)
- [x] Create `src/bindings/ZipAFolder.res` — binding for `zip`
- [x] Create `src/bindings/NodePath.res` — bindings for `node:path` (`resolve`, `join`, `dirname`) with `@variadic`
- [x] Create `src/bindings/NodeFs.res` — bindings for `node:fs` (`existsSync`, `cpSync`)
- [x] Create `src/bindings/Ora.res` — bindings for `ora` spinner (`make`, `start`, `succeed`, `fail`, `setSuffixText`)
- [x] Verify compiled `.res.mjs` output compiles (externals produce no JS — verified at use site)

## Step 7: ReScript Migration — Phase 2: Core Logic

Migrate pure logic functions to ReScript.

- [x] Create `src/DependencyBundler_Filter.res` — `isNecessary`, `isNodeScopeExcluded`, `isNodeExcluded`, `hasDependency` with `filterReason` variant for exhaustive matching
- [x] Create `src/DependencyBundler_Stats.res` — `maxDepth`, `countChildrenRecursive`, `hasChildren`, `stats` (with print)
- [x] Create `src/DependencyBundler_PostProcess.res` — post-processing hooks (`rescriptDependent`, `reventlessCore`, `deleteTests`, `deleteEffectSrc`)
- [x] Verify compiled output matches JS implementation semantics

## Step 8: ReScript Migration — Phase 3: Build Orchestration

Migrate the main `build()` function using generic naming for future extensibility.

- [x] Create `src/DependencyBundler_Config.res` — configuration types
- [x] Create `src/DependencyBundler.res` — main async build pipeline (extract, tree, filter, post-process)
- [x] Create `src/Packaging.res` — module type `T` with `package` and `publish` functions (generic interface for cloud provider backends)
- [x] Create `src/Packaging_AwsLambdaLayer.res` — AWS-specific implementation: zip + placeholder publish

## Step 9: ReScript Migration — Phase 4: Entry Point + Cleanup

Replace the JS entry point and delete all old JS files.

- [x] Create `src/Main.res` — entry point with Reventless-specific config, reading `REVENTLESS_AWS_VERSION` and `NODE_AUTH_TOKEN` from env
- [x] Update `package.json` build script: `rescript build && node ./src/Main.res.mjs`
- [x] Add package to root `rescript.json` dependencies for monorepo compilation
- [x] Delete `src/index.js`, `builder/index.js`, `builder/postprocess.js`
- [x] Remove unused `debug` dependency from `package.json`
- [x] Update CI workflow: install from monorepo root for `rescript` + `@rescript/runtime` availability
- [ ] Verify CI workflow still builds and publishes correctly
- [ ] Run full end-to-end: trigger workflow, verify layer is published to AWS

---

## Future Work (not part of this plan)

These items are tracked but deferred until prerequisites exist:

- **Layer version manifest** (Option B from analysis) — semi-automated version matching via JSON manifest attached to GitHub releases
- **Automated precompiled module rebuilding** — pre-build step that compiles ReScript packages missing JS artifacts
- **Multi-region publishing** — extend CI matrix to multiple AWS regions
- **Layer size monitoring** — warn if layer exceeds 40MB (approaching 50MB limit)
- **`Packaging_Docker` backend** — builds a container image with pre-installed `node_modules/` for Azure/GCP (only when a second provider package exists)
