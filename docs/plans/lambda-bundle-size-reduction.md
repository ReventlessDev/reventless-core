# Plan: Lambda Bundle Size Reduction

**Date**: 2026-03-20
**Analysis**: [lambda-allAggregates-code-analysis.md](../analysis/lambda-allAggregates-code-analysis.md)
**Branch**: `feat/bundeled-lambda-handlers`
**Status**: Implementation complete. Pending deploy-time validation.

---

## Problem

Bundled Lambda handlers (e.g., AllAggregates) are ~15-17 MB deployed because:
1. esbuild bundles all dependencies into `index.mjs` (~2-4 MB)
2. The Lambda layer contains those same dependencies (~13 MB zip / 44 MB uncompressed)
3. The layer also carries ~30% dead code (deploy-time packages, build tools, SSH)

**Target**: Reduce total deployed size to ~6-8 MB.

---

## Steps

### Step 1: Externalize layer packages from esbuild ✅

**File**: `reventless/reventless-aws/src/util/Util_Bundle.mjs`

Externalized: `effect`, `effect/*`, `sury`, `sury/*`, `@reventlessdev/*`, `@rescript/*`, `@standard-schema/*`, `uuid`, `hash-object`. Packages like `graphql`, `lodash`, `ramda` excluded from externals since they're also being removed from the layer (Step 3).

---

### Step 2: Enable esbuild minification ✅

**File**: `reventless/reventless-aws/src/util/Util_Bundle.mjs`

Changed `minify: false` → `minify: true`. Done in same edit as Step 1.

---

### Step 3: Clean up layer — add deploy-time exclusions ✅

**File**: `reventless/reventless-layer-builder/src/Main.res`

Added `"npmcli"` and `"gar"` to `excludeScopes`. Added 30+ packages to `excludeModules`: SSH stack, build/parse tools, process spawning, npm infrastructure, testing, and unused runtime packages (`ramda`, `lodash`, `graphql`, `jsonschema2graphql`).

---

### Step 4: Clean up layer — post-process remaining packages ✅

**Files**: `DependencyBundler_PostProcess.res` and `Main.res`

Added two new post-process functions: `deleteTestsAndExamples` (removes tests/, test/, examples/, benchmark/, docs/) and `deleteLodashExtras` (removes core.min.js, lodash.min.js, fp/). Wired `deleteTestsAndExamples` for `@reventlessdev/rescript-fast-csv` and `fast-csv` in Main.res. Note: `lodash` and `graphql` are now fully excluded via `excludeModules` (Step 3), so their post-process hooks are not needed.

---

### Step 5: Verify `ramda` and `lodash` runtime necessity ✅

Verified: neither `ramda` nor `lodash` (full package) is imported anywhere in the codebase. `graphql` is only used in the in-memory adapter (local dev), not in Lambda runtime. All three added to `excludeModules` in Step 3.

---

### Step 6: Measure and document final sizes ✅ (bundle measured; layer pending rebuild)

**Bundle measurement** (simulated AllAggregates entry point with 1 aggregate):

| Config | Size | Modules Bundled | Reduction |
|---|---|---|---|
| OLD (external: `@aws-sdk/*` only, minify: false) | **1.04 MB** | 673 | — |
| NEW (externals, minify: false) | **5.4 KB** | 7 | 99.5% |
| NEW (externals + minify: true) | **2.7 KB** | 7 | 99.7% |

The bundle now contains only the generated entry point code, the handler factory helpers, and stub imports. All framework/library code resolves from the layer at runtime.

**Layer measurement**: Pending rebuild (requires `NPM_GITHUB_TOKEN` for registry access). Expected reduction: 13 MB → ~8-10 MB based on exclusion analysis.

---

## Changes Made

| File | Change |
|---|---|
| `reventless/reventless-aws/src/util/Util_Bundle.mjs` | Expanded `external` list to externalize layer-provided packages; enabled `minify: true` |
| `reventless/reventless-layer-builder/src/Main.res` | Added 2 scopes + 30+ modules to exclusion lists; added 2 post-process hooks |
| `reventless/reventless-layer-builder/src/DependencyBundler_PostProcess.res` | Added `deleteTestsAndExamples` and `deleteLodashExtras` functions |

---

## Remaining Validation

All code changes compile with zero ReScript warnings/errors. The following require a deployment environment:

- [ ] Rebuild layer with registry auth (`npm run build` in layer-builder)
- [ ] Verify layer zip size decreased (expect 13 MB → ~8-10 MB)
- [ ] Deploy test stack — verify Lambda cold starts succeed
- [ ] Verify all handler types process events correctly (SQS, DynamoDB Stream, AppSync)
- [ ] Check no runtime import errors in CloudWatch logs
- [ ] Verify `sourceCodeHash` is deterministic (no spurious Pulumi diffs)
- [ ] Measure final bundle size per Lambda (expect < 100 KB)

---

## Risks

| Risk | Mitigation |
|---|---|
| Externalized import not found in layer at runtime | Test cold start before deploying to production. The externals list must exactly match layer contents. |
| Minification breaks handler (unlikely) | esbuild minification is well-tested for Node.js. `banner` JS is preserved. Test with a real SQS event. |
| Excluded package is actually needed at runtime | Each exclusion was verified against codebase search. Deploy to test environment first. |
| `effect` import path changes after externalization | Entry points use `import { Effect } from "effect"` which resolves to layer's `effect/` package. No path changes needed. |

---

## Success Criteria

- [ ] Bundle size per Lambda: < 100 KB
- [ ] Layer zip size: < 10 MB
- [ ] All existing integration tests pass
- [ ] No runtime import errors in CloudWatch logs after deployment
- [ ] Pulumi diff shows only code/layer changes (no spurious resource recreation)
