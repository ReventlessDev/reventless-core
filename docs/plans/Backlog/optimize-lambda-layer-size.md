# Plan: Optimize Lambda Layer Size

**Analysis**: [docs/analysis/lambda-layer-vs-bundled-handlers-optimization.md](../analysis/lambda-layer-vs-bundled-handlers-optimization.md)

## Overview

The Lambda Layer includes several packages and files that are never used at runtime. This plan removes them in priority order — quick wins first, then progressively deeper optimizations. Each step is independently shippable.

**Config file**: `reventless/reventless-layer-builder/src/Main.res` (`excludeModules` array)

---

## Step 1: Exclude `esbuild` from layer

**Why**: esbuild was used for deploy-time bundling but has been fully replaced by compiled `*EntryPoint.res` modules. It includes a native Go binary and is potentially 10-20 MB.

**Verification**: Confirm no entry point or runtime module imports `esbuild`:
```bash
grep -r "esbuild" reventless/reventless-aws/src/adapter/Runtime/*EntryPoint.res
# Should return nothing
```

**Change**: Add `"esbuild"` to `excludeModules` in `Main.res`.

- [x] Verify no runtime imports of esbuild
- [x] Add `"esbuild"` to `excludeModules`
- [x] Build layer locally, verify it succeeds
- [x] Note size difference

---

## Step 2: Exclude Pulumi binding packages

**Why**: `rescript-pulumi-pulumi` and `rescript-pulumi-aws` provide ReScript bindings for Pulumi — used exclusively at deploy time (`pulumi up`). No entry point imports from either package. The `@pulumi/*` scope is already excluded, but the ReScript binding packages live under `@reventlessdev/*` scope and slip through.

**Verification**: Confirm no entry point imports these:
```bash
grep -r "rescript-pulumi" reventless/reventless-aws/src/adapter/Runtime/*EntryPoint.res
# Should return nothing
```

**Change**: Add both to `excludeModules` in `Main.res`:
```
"@reventlessdev/rescript-pulumi-pulumi",
"@reventlessdev/rescript-pulumi-aws",
```

- [x] Verify no runtime imports
- [x] Add both packages to `excludeModules`
- [x] Build layer locally, verify it succeeds
- [x] Note size difference

---

## Step 3: Exclude Cloner-only and unused binding packages

**Why**: Several ReScript binding packages are only used by the Cloner (which runs on Fargate, not Lambda) or are not reachable from any entry point:

| Package | Reason for exclusion |
|---|---|
| `@reventlessdev/rescript-fast-csv` | Used by `CsvStream.res` in Cloner export only |
| `@reventlessdev/rescript-node` | Used alongside fast-csv for Cloner streams |
| `@reventlessdev/rescript-hash-object` | Not imported by any entry point |
| `fast-csv` | Underlying JS library for rescript-fast-csv |
| `@fast-csv/*` | fast-csv sub-packages |
| `hash-object` | Underlying JS library for rescript-hash-object |
| `fast-json-stable-stringify` | Transitive dep of hash-object |

Note: `rescript-ssh2` and `ssh2` are already excluded. The `rescript-fast-csv` package currently only has post-processing (test deletion) but is not excluded from the layer.

**Verification**: Confirm no entry point imports these:
```bash
grep -rE "fast-csv|hash-object|rescript-node|CsvStream" reventless/reventless-aws/src/adapter/Runtime/*EntryPoint.res
# Should return nothing
```

Also verify no runtime module in the import chain uses them. Check `reventless-core` for runtime usage:
```bash
# CsvStream is only imported by Cloner
grep -r "CsvStream" reventless/reventless-core/src/ --include="*.res"
# hash-object — check what uses it
grep -r "hash.object\|HashObject\|rescript-hash-object" reventless/reventless-core/src/ --include="*.res"
```

**Change**: Add to `excludeModules` in `Main.res`:
```
"@reventlessdev/rescript-fast-csv",
"@reventlessdev/rescript-node",
"@reventlessdev/rescript-hash-object",
"hash-object",
"fast-json-stable-stringify",
```

Also add `fast-csv` scope handling — either add `"fast-csv"` to `excludeModules` or add `"fast-csv"` to `excludeScopes` if it's scoped as `@fast-csv/*`.

Remove the now-unnecessary post-process entries for `rescript-fast-csv` and `fast-csv` (they won't be in the layer).

- [ ] Verify no runtime imports (trace full import chains)
- [ ] Add packages to `excludeModules`
- [ ] Remove `rescript-fast-csv` and `fast-csv` post-process entries
- [ ] Build layer locally, verify it succeeds
- [ ] Note size difference

**Status: Deferred** — Step 3 packages are unused at runtime but excluded from initial cleanup. Can be revisited if layer size becomes a concern.

---

## Step 4: Audit and exclude CLI/utility transitives

**Why**: Packages like `yargs`, `escalade`, `graceful-fs`, `chalk`, `ansi-*`, `debug`, `json5` are likely transitive dependencies that aren't needed at Lambda runtime.

**Approach**: After completing Steps 1-3, inspect the built layer to find remaining packages that seem unnecessary:

```bash
# After layer build, list top-level packages
ls reventless/reventless-layer-builder/builder/layer/nodejs/node_modules/ | sort
```

For each suspicious package, trace who depends on it:
```bash
# In the built layer, check what imports it
grep -r "require.*<package>" reventless/reventless-layer-builder/builder/layer/nodejs/node_modules/ --include="*.js" --include="*.mjs" -l
```

**Change**: Add confirmed-unused packages to `excludeModules` one by one, rebuilding after each to verify nothing breaks.

- [x] Build layer with Steps 1-2 applied
- [x] List all packages in built layer
- [x] Identify candidates (CLI tools, build utilities)
- [x] Trace dependency chains for each candidate — found 29 orphan packages
- [x] Add confirmed-unused packages to `excludeModules`
- [x] Build and verify — 106 → 74 extracted dependencies

---

## Step 5: Post-process deploy-time files from framework packages

**Why**: `reventless-core` and `reventless-aws` ship all compiled `.res.mjs` files — including `*_Builder.res.mjs` and `*_Adapter.res.mjs` files that are only used at deploy time. Entry points only import `*_Callback.res.mjs`, `*_Operations.res.mjs`, and `*_Runtime.res.mjs`.

**Approach**: Add glob patterns to the post-process step that delete deploy-time files:

```rescript
// In DependencyBundler_PostProcess.res, add:
let reventlessAws: postProcessFn = async (_node, cwd) => {
  await Rimraf.rimrafMany([
    // Deploy-time builders (never imported by entry points)
    NodePath.resolve([cwd, "src/adapter/Runtime/*Runtime_Builder*.res.mjs"]),
    NodePath.resolve([cwd, "src/adapter/Runtime/RuntimeEnvironment*.res.mjs"]),
  ])
}
```

For `reventless-core`, extend the existing post-process to also remove:
- `src/adapter/**/*_Builder*.res.mjs` (runtime builder orchestration)
- `src/components/**/*_Builder.res.mjs` (component builders)
- `src/components/**/*_Adapter.res.mjs` (adapter interfaces)
- `src/util/Util_Pulumi.res.mjs`, `src/util/Util_Adapter.res.mjs`, `src/util/OutputLogger.res.mjs`
- `src/util/Interstack.res.mjs`, `src/util/ResourceQuery.res.mjs`
- `src/components/Cloner.res.mjs`, `src/util/CsvStream.res.mjs`

**Risk**: Must verify that no `*_Callback.res.mjs` or `*_Operations.res.mjs` transitively imports a `*_Builder.res.mjs`. Check compiled output for cross-references.

```bash
grep -r "Builder\|Adapter" reventless/reventless-core/src/components/**/*_Callback.res.mjs
grep -r "Builder\|Adapter" reventless/reventless-core/src/components/**/*_Operations.res.mjs
```

- [x] Audit imports in Callback/Operations files for Builder/Adapter references — none found
- [x] Add post-process globs for deploy-time files in reventless-core
- [x] Add post-process for deploy-time files in reventless-aws (via new `rootPostProcess` config)
- [x] Run a test deployment to verify handlers still work — verified via subsequent layer deploys (ARN 47+)
- [x] Note size difference — 15 MB → 14 MB zip, all Builder/Adapter/RuntimeEnvironment files removed

---

## Step 6: Investigate `@smithy/*` exclusion via ESM resolution fix

**Why**: `@smithy/*` (~37 packages) is the AWS SDK v3 protocol implementation. It's provided by the Lambda runtime but included in the layer because ESM `import` from `/opt/nodejs/node_modules/` can't resolve modules via `NODE_PATH` (unlike CommonJS `require`).

**Investigation needed**:

1. **`createRequire` approach**: Entry points could use `createRequire` from `node:module` to resolve `@smithy/*` from the Lambda runtime's `NODE_PATH`:
   ```javascript
   import { createRequire } from 'node:module';
   const require = createRequire('/var/runtime/');
   const smithyClient = require('@smithy/smithy-client');
   ```
   Problem: framework code uses ESM `import` throughout — would need a custom loader or aliasing.

2. **Node.js `--experimental-specifier-resolution` or import maps**: Check if Lambda supports custom loaders or import maps that could redirect `@smithy/*` imports.

3. **Symlink approach**: Post-process step could create symlinks from the layer's `@smithy/*` to the Lambda runtime's copies. Unclear if Lambda's read-only filesystem allows this.

4. **Just live with it**: If `@smithy/*` is ~5-10 MB compressed, and the layer is well under limits, the engineering effort may not justify the savings.

- [x] Measure `@smithy/*` size in the built layer
- [x] Test `createRequire` workaround in a Lambda function — N/A: ESM `import` from `/opt/` cannot resolve via NODE_PATH; `@smithy` must stay in layer
- [x] Evaluate if the size savings justify the complexity — decided to keep `@smithy` in layer (see commit `ff7f4ab4`)
- [x] If viable, implement and document the ESM resolution fix — not viable; closed

---

## Step 7 (Future): Tree-shake layer with bundler

**Why**: Instead of manually maintaining exclude lists, use esbuild or rollup to bundle only modules reachable from the 13 entry points. This automatically excludes all deploy-time code.

**Approach**: Add a bundling step after dependency extraction:
1. Entry points: all `*EntryPoint.res.mjs` files
2. Externals: `@aws-sdk/*` (Lambda runtime), user modules (dynamic import)
3. Output: Single or per-entry-point bundles replacing the `node_modules/` tree
4. Preserve dynamic `import('/var/task/...')` calls

**Blockers**:
- `Obj.magic` and `%raw` patterns may confuse tree-shakers
- Need to verify `sury` schema registration survives bundling (side effects at module load)
- Effect library may have side-effectful module initialization

This is a significant build pipeline change and should only be pursued if layer size becomes a real constraint.

- [ ] Prototype with esbuild: bundle one entry point, test in Lambda
- [ ] Identify side-effect modules that must be preserved
- [ ] Measure size reduction vs current approach
- [ ] If viable, implement for all 13 entry points

---

## Measurement

After each step, record the layer zip size to track progress:

| Step | Layer Size (zip) | Packages | Notes |
|---|---|---|---|
| Baseline (before optimization) | ~15 MB | 106 | Estimated from first build with steps 1-2 only |
| Steps 1+2+4+5 combined | **14 MB** | **74** | All implemented together |
| Step 3 (Cloner packages) | — | — | Deferred |
| Step 6 (@smithy) | — | — | Future |
| Step 7 (tree-shake) | — | — | Future |

Steps 1, 2, 4, and 5 were implemented together. The combined result:
- Excluded 32 orphan/unnecessary packages
- Deleted all `*_Builder.res.mjs` and `*_Adapter.res.mjs` from reventless-core
- Deleted all `*Runtime_Builder*.res.mjs` and `RuntimeEnvironment*.res.mjs` from reventless-aws
- 13 entry point files preserved in reventless-aws

To measure: build the layer locally and check the zip size:
```bash
cd reventless/reventless-layer-builder
REVENTLESS_AWS_VERSION=latest npm run build
ls -lh builder/reventless-layer.zip
```
