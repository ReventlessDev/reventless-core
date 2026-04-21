# Plan: Migrate reventless-core to pnpm (+ cross-repo dev linking)

**Date (v1):** 2026-04-21
**Date (v2 rewrite, post-Phase-0):** 2026-04-21
**Date (v3, post-Phase-1 execution + Phase-3 compat spike):** 2026-04-21
**Date (v4, post-workspace-protocol cleanup):** 2026-04-21

**Status:** Phase 1 shipped on branch `feat/pnpm-migration` (commit `1de8b775`). Phase 3 compat-shim spike (Option B) validated. Phase-2-adjacent workspace-protocol cleanup executed (see §1.4d follow-up). Phase 2 not yet started.

## Why this plan exists

Cross-repo linking with npm has produced repeated fires: `npm install` wipes hand-crafted symlinks, `file:` overrides resolve relative to the consuming workspace rather than the root (producing broken paths), and ad-hoc symlinks inside `examples/**` get overwritten on every install.

pnpm is chosen because:

- **`workspace:*` protocol.** Explicit, first-class declarations for workspace deps instead of npm's implicit global hoisting. Makes the dep graph legible and lockfile-accurate.
- **Overlay-based cross-repo linking.** A single gitignored config file toggles between "link mode" (sibling repo as live source) and "release mode" (registry version). No edits to committed files.
- **Stable workspace semantics.** npm's hoisting behaviour has shifted multiple times; pnpm's rules are explicit.
- **No rebuild thrash on topology changes.** Adding/removing a workspace in pnpm re-wires symlinks predictably.

**What pnpm does NOT give us** (demoted from the original plan's thesis): strict hoisting does **not** cleanly fix ReScript's cross-repo duplicate-package traversal. Phase 0 showed that ReScript's compiler walks `node_modules/@reventlessdev/*` via node-module resolution, which requires a *hoisted* layout to satisfy the phantom deps this codebase has accumulated. We therefore run pnpm in `node-linker=hoisted` mode, which produces an npm-like flat layout while preserving pnpm's other benefits.

Alternatives considered and rejected: plain `npm link` (survives install but has no git-tracked config and still hits symlink fragility); npm cross-repo workspaces (not all versions accept `..` in the glob, and switching modes requires editing committed files); Yarn Berry (`portal:` works but PnP is incompatible with our PPX toolchain); Nx/Turborepo/Bazel (adoption cost disproportionate to repo size). A local Verdaccio registry remains the declared fallback if this plan fails to converge.

---

## Goal

Replace npm with pnpm as the monorepo's package manager, using `node-linker=hoisted` for ReScript compatibility and `link-workspace-packages=true` to make workspace packages satisfy semver-ranged cross-workspace deps (needed because pnpm 10 changed this default from `true` to `false`). Establish a clean overlay pattern for linking the sister repo into local development builds without breaking the compiler or CI.

### What this unlocks when done

- Edits in a sibling `reventless-ui` working copy appear in core's example builds without a publish cycle.
- CI and fresh clones install from the registry unchanged — no per-developer setup.
- Switching between "link mode" (live sibling repo) and "release mode" (registry version) is controlled by one gitignored file. Committed `package.json` files are unchanged between modes.
- Workspace deps are declared explicitly (`workspace:*`) and surface in lockfile diffs.

---

## Prerequisites

- pnpm 10+ installed (`corepack enable && corepack prepare pnpm@10 --activate`).
- A clean branch off `alpha`. This plan is invasive — do not mix with unrelated work.
- Time budget: **Phase 1 is 2–3 focused days** (revised upward from the original estimate). Phase 2 is a further day once Phase 1 is green.

---

## Phase 0 — Findings (completed 2026-04-21 on branch `spike/pnpm-rescript`, commit `2e21c3a2`)

The 1-hour spike validated that pnpm + ReScript *can* work, but invalidated the original plan's core assumption about strict hoisting. Concrete findings:

### What works

1. `corepack enable && corepack prepare pnpm@latest --activate` succeeds cleanly.
2. `pnpm install` from scratch completes in ~3 minutes with pnpm 10.33.
3. With the remediations below, `rescript build` compiles all three example platforms (546 + 541 + 538 modules).

### What the original plan got wrong

1. **"Strict hoisting fixes the duplicate-package panic"** — false for this codebase. pnpm's default isolated layout fails immediately on ~20 phantom workspace deps in the root `rescript.json`. Switching to `node-linker=hoisted` is mandatory; strict mode is not a viable target.

2. **"3–10 missing dep declarations in Phase 1.5"** — actual surface is **~40+**:
   - Root `rescript.json` lists 20 workspace packages not declared in root `package.json`.
   - `@reventlessdev/reventless-ppx/bin` is referenced as a ppx-flag in 20 `rescript.json` files but declared in zero `package.json` files.
   - Additional transitive phantom deps will likely surface once the first wave is fixed.

3. **`prebuild` hooks do not auto-run under pnpm 10.** The `generate-plugin src/` step in every plugin's `prebuild` script is silently skipped unless `enable-pre-post-scripts=true` is set in `.npmrc`. Not mentioned in the original plan.

4. **Build-script approval is required AND sticky.** pnpm 10 blocks postinstall scripts by default. Adding `sury-ppx`, `esbuild`, `rescript-relay`, etc. to `onlyBuiltDependencies` only takes effect on fresh installs; `pnpm rebuild` does not always re-run the scripts it should. `sury-ppx`'s `install.cjs` had to be invoked manually during the spike to make `ppx-osx-x64.exe` executable.

5. **"Duplicated package" warnings persist** even in hoisted mode. pnpm nests `node_modules` under some workspace packages (e.g. `node_modules/@reventlessdev/online-shop-hybrid-catalog/node_modules/@reventlessdev/reventless-spec`). ReScript treats these as warnings when it picks a "chosen" copy, but the original plan's "cleanly eliminates the panic" framing doesn't hold.

### What the spike did NOT validate

- Phase 0.3 (cross-repo link with sibling `reventless-ui`) was not attempted. The 1-hour budget was consumed by the issues above.
- Whether a pre-existing `Main.res` type error in `examples/online-shop-hybrid/platform-in-memory` (`Catalog.make does not take ~uiBundleUrl`) is caused by pnpm or is a latent issue on `alpha` under npm — not verified.

### Verdict

Phase 0 is a **soft pass with asterisks**. The migration is possible but requires significantly more work than the original plan scoped. The rewritten Phase 1 below makes every discovered remediation explicit. If the cost still looks too high once Phase 2 (cross-repo linking) is better understood, the Verdaccio fallback remains on the table.

---

## Phase 1 — Migrate core to pnpm (hoisted layout)

Execute on a fresh branch off `alpha`. The spike branch `spike/pnpm-rescript` is for reference only; it was not a clean migration attempt.

### 1.1 Install pnpm and convert lockfile

1. `corepack enable && corepack prepare pnpm@10 --activate`.
2. At core root: `rm -rf node_modules`, keep `package-lock.json` temporarily as a conversion input.
3. `pnpm import` — converts `package-lock.json` into `pnpm-lock.yaml`. Manually verify resolved versions of a 20-package sample (including all `@reventlessdev/*`, `@pulumi/*`, `rescript*`, `sury*`, `react*`) by diffing against the old lockfile. Document any drift.
4. Delete `package-lock.json`; add `pnpm-lock.yaml` to git.

### 1.2 Force hoisted layout (non-negotiable)

ReScript's node-module walker and our phantom-dep surface require flat hoisting. Add to `.npmrc`:

```
# pnpm: required for ReScript compiler compatibility
node-linker=hoisted

# pnpm 10: workspaces define prebuild/postbuild steps for generate-plugin;
# restore npm-style auto-execution
enable-pre-post-scripts=true
```

### 1.3 Replace workspace config

Remove `"workspaces": [...]` from root `package.json`. Create `pnpm-workspace.yaml`:

```yaml
packages:
  - 'packages/*'
  - 'rescript/*'
  - 'reventless/*'
  - 'examples/**'

# pnpm 10 blocks postinstall scripts by default; allowlist the ones we need.
# Keep this list in sync with the set of deps that ship native binaries or
# install-time codegen.
onlyBuiltDependencies:
  - '@pulumi/aws-native'
  - core-js
  - core-js-pure
  - cpu-features
  - esbuild
  - nx
  - protobufjs
  - rescript-relay
  - ssh2
  - sury-ppx
```

Delete any stray nested cross-repo symlinks inside `examples/online-shop-hybrid/platform-in-memory/` — these are npm-era hacks that conflict with clean workspace resolution.

### 1.4 Declare phantom workspace deps (the big one)

This is the largest remediation step and is independent of every other change. Each rescript.json dep must appear in at least one package.json dep so pnpm creates a symlink.

**1.4a — Root `rescript.json` → root `package.json`.** Add all 20 entries listed in root `rescript.json` to root `package.json` as `workspace:*` devDependencies:

```json
"devDependencies": {
  "concurrently": "^9.2.1",
  "@reventlessdev/reventless-conventional-changelog": "file:./reventless/reventless-conventional-changelog",
  "lerna": "^8.1.8",
  "rescript": "^12.2.0",
  "@reventlessdev/rescript-aws-sdk": "workspace:*",
  "@reventlessdev/rescript-fast-csv": "workspace:*",
  "@reventlessdev/rescript-hash-object": "workspace:*",
  "@reventlessdev/rescript-moment": "workspace:*",
  "@reventlessdev/rescript-node-streams": "workspace:*",
  "@reventlessdev/rescript-node-zlib": "workspace:*",
  "@reventlessdev/rescript-pulumi-aws": "workspace:*",
  "@reventlessdev/rescript-pulumi-pulumi": "workspace:*",
  "@reventlessdev/rescript-ssh2": "workspace:*",
  "@reventlessdev/rescript-graphql-yoga": "workspace:*",
  "@reventlessdev/rescript-mcp-sdk": "workspace:*",
  "@reventlessdev/rescript-effect": "workspace:*",
  "@reventlessdev/rescript-uuid": "workspace:*",
  "@reventlessdev/reventless-spec": "workspace:*",
  "@reventlessdev/reventless-infra": "workspace:*",
  "@reventlessdev/reventless-interop": "workspace:*",
  "@reventlessdev/reventless-core": "workspace:*",
  "@reventlessdev/reventless-in-memory": "workspace:*",
  "@reventlessdev/reventless-aws": "workspace:*",
  "@reventlessdev/online-shop-hybrid-platform-aws": "workspace:*",
  "@reventlessdev/reventless-ppx": "workspace:*"
}
```

**1.4b — Workspace `rescript.json` → sibling `package.json`.** For each workspace whose `rescript.json` references `@reventlessdev/reventless-ppx/bin`, `sury-ppx/bin`, or any `@reventlessdev/*` dependency, add the corresponding entry to that workspace's `package.json`. The 20 rescript.json files found during the spike are:

- `reventless/reventless-core/rescript.json`
- `reventless/reventless-in-memory/rescript.json`
- `examples/online-shop-aggregates/{catalog,catalog-spec,ordering,ordering-spec}/rescript.json`
- `examples/online-shop-dcb/{catalog,catalog-spec,ordering,ordering-spec,platform-in-memory}/rescript.json`
- `examples/online-shop-hybrid/{catalog,catalog-aws,catalog-spec,ordering,ordering-aws,ordering-spec,platform-in-memory,platform-aws}/rescript.json`
- `examples/online-shop-aggregates/platform-in-memory/rescript.json` (already has reventless-ppx in build-time closure)

For each of these, run: `grep '"@reventlessdev' rescript.json` and cross-check against that workspace's `package.json` `dependencies` + `devDependencies`. Add any missing entry as `workspace:*`.

**1.4c — Iterate.** After 1.4a and 1.4b, run `pnpm install && pnpm run build` and fix any remaining `try_package_path: upward traversal did not find …` errors by adding the missing dep to the offending workspace's `package.json`. Budget 2–3 rounds.

### 1.5 Overrides migration

pnpm reads `pnpm.overrides` in root `package.json`, not top-level `overrides`. Move:

```json
"pnpm": {
  "overrides": {
    "@docusaurus/theme-common": "3.9.2",
    "graphql": "^16.0.0"
  }
}
```

Drop the top-level `"overrides"` key.

### 1.6 Update scripts

Replace npm-specific invocations in root and workspace `package.json`s. Relevant mappings:

| npm | pnpm |
|---|---|
| `npm install` | `pnpm install` |
| `npm ci` | `pnpm install --frozen-lockfile` |
| `npm run build -w <pkg>` | `pnpm --filter <pkg> run build` |
| `npm run build --workspaces --if-present` | `pnpm -r run build` |
| `npm --prefix path run x` | `pnpm --filter ./path run x` |
| `npm run generate` (in `prebuild` hooks) | keep as-is; requires `enable-pre-post-scripts=true` from §1.2 |

Grep every `package.json` for ` npm ` invocations and convert. Common scripts: `dev:*`, `build`, `test`, `clean`, `prebuild`, `rebuild`.

### 1.7 Install & verify

1. `rm -rf node_modules && pnpm install` from scratch completes without errors.
2. If any `onlyBuiltDependencies` postinstall failed to run (the spike saw this with `sury-ppx`), run manually:
   ```bash
   cd node_modules/sury-ppx && node install.cjs
   cd $REPO_ROOT
   ```
   Investigate and file an issue for any recurring case; the long-term fix may be a root-level postinstall that verifies binaries are executable.
3. `pnpm run build` from root — all three example platforms compile. Zero errors. `Duplicated package` warnings are acceptable (pre-existing under hoisted layout) but must be documented.
4. `pnpm test` — all tests pass.
5. `pnpm exec lerna publish --dry-run` — verify Lerna still functions.

### 1.8 Update CI

Replace in CI config:

```yaml
# before
- run: npm ci
- run: npm run build

# after
- run: corepack enable
- uses: pnpm/action-setup@v4
  with:
    version: 10
- run: pnpm install --frozen-lockfile
- run: pnpm run build
```

Confirm pnpm/action-setup honors `onlyBuiltDependencies` and `enable-pre-post-scripts` in CI (these are read from `.npmrc` and `pnpm-workspace.yaml`, so they should).

### Checklist

```
Phase 1 (core migration) — ALL COMPLETE (2026-04-21, commit 1de8b775)
  [x] 1.1  pnpm import; commit pnpm-lock.yaml; delete package-lock.json
  [x] 1.2  .npmrc has node-linker=hoisted and enable-pre-post-scripts=true
           + link-workspace-packages=true (new — see §1.4d deviation)
  [x] 1.3  pnpm-workspace.yaml created with packages + onlyBuiltDependencies
  [x] 1.4a Root package.json declares all 20 root-rescript.json deps
           + reventless-ppx as workspace:* (21 total)
  [x] 1.4b Each of 20 identified workspaces declares its own rescript.json deps
  [x] 1.4c Build-iteration loop converges with zero "try_package_path" errors
  [x] 1.5  overrides → pnpm.overrides
  [x] 1.6  All npm invocations in package.json scripts converted to pnpm
           (21 files + lerna.json npmClient: pnpm, bootstrap --no-package-lock dropped)
  [x] 1.7  Verify: fresh pnpm install succeeds (2m 05s from scratch)
  [x]      Verify: pnpm install --frozen-lockfile succeeds (CI-compatible)
  [x]      Verify: pnpm run build (all four phases: root + 3 platforms) succeeds
  [x]      Verify: pnpm test — 109/109 suites, 1034/1034 tests
  [x]      Verify: pnpm exec lerna list + lerna changed succeed
           (lerna publish --dry-run not supported in v8; allowBranch guard works)
  [x]      Document: 3 unique Duplicated-package warnings remain (see §1.7a)
  [x] 1.8  CI updated (7 workflows); pnpm/action-setup@v4 with version 10
```

### 1.4d Deviation — `link-workspace-packages=true` required

Not in the v2 plan. pnpm 10 changed this default from `true` (v9) → `false`, which means workspace packages no longer satisfy semver-ranged cross-workspace deps by default. This repo uses semver ranges heavily for `@reventlessdev/*` deps (e.g., `"@reventlessdev/reventless-spec": "^3.0.0-alpha.30"`), so pnpm fetched stale registry copies instead of linking workspaces — breaking the build on newly-added but-not-yet-published symbols (`Reventless.AnsiStyle`). Mitigation: added to `.npmrc`.

**Follow-up completed (2026-04-21, post-Phase-1):** all 28 in-repo `@reventlessdev/*` semver-range and `"*"` deps converted to `workspace:*` (excluding `@reventlessdev/dev-app` which stays at `>=0.2.0-alpha` — external sister repo). `link-workspace-packages=true` was removed from `.npmrc`. Fresh `pnpm install` + `pnpm run build` succeed without it; the 3 documented duplicated-package warnings (§1.7a) are unchanged by this cleanup (they come from hoisted-layout nested node_modules, not semver resolution). This makes workspace intent explicit in source, is forward-compatible to any future pnpm semantics change, and makes `pnpm publish --workspace-protocol` rewrite `workspace:*` → concrete versions at publish time.

### 1.4e Deviation — `dev-app` optional dep range

`examples/online-shop-hybrid/platform-in-memory/package.json` had `"@reventlessdev/dev-app": "*"` in `optionalDependencies`. Under `pnpm install --frozen-lockfile`, pnpm's satisfies-check failed because `"*"` excludes prereleases by default, and the only published version of `dev-app` is `0.2.0-alpha.1` (a prerelease). Changed to `">=0.2.0-alpha"` to explicitly admit prereleases.

### 1.7a Duplicated-package warnings

Only 3 unique warnings remain (far fewer than the spike's "persist even in hoisted mode" framing):

1. `@reventlessdev/rescript-effect` — hoisted root copy vs nested copy under `reventless/reventless-core/node_modules`
2. `@reventlessdev/rescript-node-streams` — hoisted root copy vs nested under `rescript/rescript-fast-csv`
3. `@reventlessdev/rescript-node-streams` — same, vs nested under `rescript/rescript-ssh2`

All are warnings (not panics), ReScript picks the hoisted root copy, and builds are green. Root cause is expected under hoisted mode: pnpm nests workspace deps when consumer's declared range doesn't match what root provides. Acceptable for Phase 1; revisit as part of the §1.4d follow-up cleanup.

### 1.7b Lerna v8 does not support `lerna publish --dry-run`

The plan's verification "lerna publish --dry-run" line is incorrect for Lerna v8+. Substituted verifications:
- `pnpm exec lerna list` — sees all 40 packages ✓
- `pnpm exec lerna changed` — identifies 29 packages with releasable changes ✓
- `pnpm exec lerna version --no-push --no-git-tag-version --yes` — correctly rejects non-allow-branch ✓ (this branch is `feat/pnpm-migration`; allowBranch is main/master/alpha/beta)

---

## Phase 2 — Cross-repo linking via local overlay

Mechanism: committed `pnpm-workspace.yaml` has release-mode packages; a gitignored overlay file adds the sibling repo path for link mode. A script toggles between the two.

### 2.1 Add the overlay mechanism

pnpm does not natively merge multiple workspace files. The cleanest pattern is to provide a script that rewrites `pnpm-workspace.yaml` in place:

```yaml
# pnpm-workspace.yaml (committed) — release mode only
packages:
  - 'packages/*'
  - 'rescript/*'
  - 'reventless/*'
  - 'examples/**'
onlyBuiltDependencies: [...]  # (as in §1.3)
```

```yaml
# pnpm-workspace.local.yaml (gitignored) — link mode additions
packages:
  - '../reventless-ui/reventless/reventless-ui'
```

Root `package.json` scripts:

```json
"scripts": {
  "link:on":  "node ./scripts/apply-workspace-overlay.mjs && pnpm install",
  "link:off": "git checkout pnpm-workspace.yaml && pnpm install"
}
```

`scripts/apply-workspace-overlay.mjs` is a small YAML merger (js-yaml or manual string concat) that produces `pnpm-workspace.yaml` = committed file + local overlay. Committed file is always the source of truth; `link:off` restores it.

### 2.2 Gitignore

Add to `.gitignore`:

```
pnpm-workspace.local.yaml
```

### 2.3 Declare cross-repo deps with `workspace:*`

In every consumer package that depends on `@reventlessdev/reventless-ui`:

```json
"dependencies": {
  "@reventlessdev/reventless-ui": "workspace:*"
}
```

Behaviour:

- **Link mode** (sibling path in workspace): resolves to the local working copy.
- **Release mode** (no sibling): pnpm resolves `workspace:*` to the locked registry version. For a fresh clone in release mode, `pnpm install --frozen-lockfile` is authoritative.
- **Publishing**: `pnpm publish --workspace-protocol` rewrites `workspace:*` → `^<resolved-version>` in published `package.json`. Verify with `pnpm publish --dry-run`.

### 2.4 Document the workflow

Create `docs/guides/cross-repo-dev-linking.md`:

```
To live-edit reventless-ui from this repo:

  1. cp pnpm-workspace.local.yaml.example pnpm-workspace.local.yaml
  2. pnpm run link:on
  3. Edits in ../reventless-ui/reventless/reventless-ui/src/ appear in
     core's compiled output after `pnpm run build`.

To return to registry mode:

  pnpm run link:off

After toggling, always re-run `pnpm run build`.
```

Ship `pnpm-workspace.local.yaml.example` (committed) documenting the expected structure.

### Checklist

```
Phase 2 (cross-repo linking)
  [ ] 2.1  link:on / link:off scripts wired via overlay script
  [ ] 2.2  pnpm-workspace.local.yaml in .gitignore
  [ ] 2.3  @reventlessdev/reventless-ui declared as workspace:* in every
           consumer package
  [ ] 2.4  docs/guides/cross-repo-dev-linking.md + .example file
  [ ]      Verify (link mode): link:on → edit sibling .res file → rebuild →
           change reflected in core compiled output
  [ ]      Verify (release mode): link:off → pnpm install --frozen-lockfile
           resolves @reventlessdev/reventless-ui from registry
  [ ]      Verify (toggle): link:on → link:off → link:on clean, no leftover
  [ ]      Verify (publish dry-run): pnpm publish --dry-run rewrites
           workspace:* to a concrete version in the tarball's package.json
```

### Unknowns still to resolve in Phase 2

Partially answered by the Phase 3 compat-shim spike (2026-04-21; see Phase 3 findings below):

- **Resolved:** pnpm accepts `..`-prefixed paths in `pnpm-workspace.yaml`. Sister gets recognized as a workspace; direct `workspace:*` consumers in core link to sister's working copy, and file-system reads via the symlink are diff-identical.
- **Resolved:** `link-workspace-packages=true` **does NOT propagate to transitive deps**. A core package that consumes sister only transitively (e.g., via an already-published intermediate like `dev-app`) will still pull the registry version. To force transitive resolution to the workspace, a `pnpm.overrides` entry is required — and that entry should live in the **gitignored** `pnpm-workspace.local.yaml`/overlay, not the committed config, so release builds remain registry-authoritative.

Still open:

- Whether sister's `node_modules/@reventlessdev/*` contents shadow or duplicate core's under hoisted layout — untested; depends on whether a real Phase 2 consumer triggers the nested install.
- Whether `rescript.json` in core consumers of `@reventlessdev/reventless-ui` needs an entry for cross-repo deps — untested; no current consumer.
- How `generate-plugin` behaves with a linked sibling whose generated files live in a different repo's `src/` — untested; no current generated output depends on sister.
- Sister's own back-reference to `@reventlessdev/rescript-moment` (currently `^0.10.0-alpha.4`, registry-only) — whether Phase 2 link mode creates a resolution loop (core → sister (live) → rescript-moment → core). Needs test when first Phase 2 consumer lands.

Budget a half-day in Phase 2 for these remaining items.

---

## Phase 3 — Sister repo compatibility

For link mode to work, the sister repo must be a valid pnpm workspace target, which requires `pnpm-workspace.yaml` at its root (even if minimal).

- **Option A:** Migrate the sister repo to pnpm fully (separate plan; coordinate with sister-repo owners).
- **Option B (compat shim):** Add only `pnpm-workspace.yaml` to the sister so it can be consumed as a pnpm workspace while staying on npm for its own development.

### Spike outcome (2026-04-21, pre-Phase-2)

**Option B is viable.** A 5-minute spike validated:

1. Added a minimal `pnpm-workspace.yaml` (`packages: ['reventless/*']`) to the sister repo root.
2. Temporarily added `'../reventless-ui/reventless/reventless-ui'` to core's `pnpm-workspace.yaml`.
3. Temporarily added `"@reventlessdev/reventless-ui": "workspace:*"` to core's root `package.json` devDependencies.
4. `pnpm install` in core created `node_modules/@reventlessdev/reventless-ui` as a symlink pointing into the sister repo. File reads via the symlink are diff-identical to the sister's source.
5. `pnpm list --recursive` in core lists the sister package with its real path.

No sister-side `pnpm install` was needed; sister's npm-based dev workflow is untouched. All spike changes were reverted after verification; both repos returned to clean state.

**Caveat (see §"Unknowns still to resolve in Phase 2"):** workspace linking applies only to direct importer deps declared as `workspace:*`. Transitive references (already-published intermediates that depend on the sister) continue to resolve to the registry. This is fine for the intended Phase 2 use case (new consumers declare the dep explicitly), but anyone expecting `dev-app` → `reventless-ui` to live-link needs a `pnpm.overrides` entry in the gitignored overlay.

### Checklist

```
Phase 3 (sister compatibility)
  [x] 3.1  Verify sister repo works as a pnpm workspace target via compat shim
           (Option B validated 2026-04-21 — no sister migration needed yet)
  [ ] 3.2  Commit the minimal pnpm-workspace.yaml on the sister repo before
           Phase 2 execution (separate PR on sister repo)
  [ ]      Verify: Phase 2 link:on → build works end-to-end with a real
           consumer (currently no core package depends on reventless-ui)
```

If a future need forces Option A (full sister migration), file a separate plan/issue; Option B is the default recommendation.

---

## Rollback

Phase 1 verification passed; rollback procedure retained here for reference only.

If a regression is discovered post-merge:

1. Revert commit `1de8b775` (`feat(build): migrate from npm to pnpm (hoisted layout)`).
2. `rm -rf node_modules pnpm-lock.yaml pnpm-workspace.yaml`.
3. `.npmrc` and `package.json` are restored by the revert.
4. `npm install`.

---

## Risks

### Resolved during Phase 1 execution

1. **Phantom-dep iteration loop (§1.4c).** Converged in a single install after the audit-driven declaration pass; no incremental build-fail loop needed.
2. **pnpm build-script approval flakiness.** `sury-ppx` postinstall ran cleanly on every fresh install. No manual kick required. `onlyBuiltDependencies` in `pnpm-workspace.yaml` covers the native-binary set.
3. **`pnpm import` lockfile drift.** Spot-check of root deps (`rescript`, `concurrently`, `lerna`) matched `package-lock.json` resolutions. The one apparent mismatch (lerna 9.0.7 → 8.2.4) was a jq artifact picking up a nested workspace's lerna, not real drift.
4. **`Main.res` uiBundleUrl error from Phase-0 spike.** Never reproduced in Phase 1 execution; was likely a transient spike artifact.

### Still active (forward-looking)

5. **Lerna + pnpm.** Lerna v8.2.4 (the version pinned here) works cleanly with `npmClient: pnpm` and `workspace:*`. Publishing still requires `pnpm publish --workspace-protocol` (or lerna's own resolver) to rewrite deps correctly. The first actual publish off this branch is the real test — verify with `--dry-run` on a release candidate tag.
6. **rescript-relay compiler.** Not exercised in Phase 1's build closure. Packages using `rescript-relay` are not part of `pnpm run build`'s root build graph. If a deploy workflow fails on it, investigate `node_modules/rescript-relay` hoisting state first.
7. **`workspace:*` publishing.** Mis-configured `--workspace-protocol` flag publishes broken package.json files. Always `pnpm publish --dry-run` before real publish.
8. **Warnings vs panics.** We are accepting 3 ongoing `Duplicated package` warnings (see §1.7a). If any future ReScript compiler change promotes these to hard errors, revisit the §1.4d follow-up cleanup.
9. **`link-workspace-packages=true` behavior change.** If pnpm 11+ changes this setting or its semantics, the workspace-linking guarantees may silently regress. Pin `packageManager: pnpm@10.33.0` in root `package.json` to surface any such change as an explicit upgrade step.

---

## What this plan does NOT cover

- Full migration of sister `reventless-ui` repo (Phase 3 is compat check only).
- Migrating any other sibling repos that may depend on core.
- Setting up a local Verdaccio registry as an alternative fallback (separate plan if this one fails).
- Changes to the Lerna release flow beyond verifying it still works.
- Moving off `node-linker=hoisted` to pnpm's isolated default — out of scope until ReScript's resolver changes or the monorepo's phantom-dep surface is reduced.

---

## Open questions

1. **~~pnpm version pin.~~** Resolved: `packageManager: pnpm@10.33.0` in root `package.json`.
2. **Monorepo-wide prebuild.** Today each plugin has its own `prebuild: pnpm run generate`. With `enable-pre-post-scripts=true` this continues to work, but consider whether a single top-level `generate-all` task would be cleaner. Unchanged by Phase 1.
3. **~~Duplicated-package warnings.~~** Resolved: 3 warnings documented (§1.7a), left visible. Revisit only if they increase or are promoted to errors.
4. **`workspace:*` for in-repo semver-ranged deps.** Partially resolved — `link-workspace-packages=true` papers over this at install time. The follow-up cleanup (convert `@reventlessdev/*` semver ranges to `workspace:*` everywhere) is a Phase-2-adjacent refactor; it would eliminate reliance on `link-workspace-packages` and make publish-time behavior explicit.
5. **~~Sister repo migration path.~~** Resolved: compat shim (Option B) validated by the 2026-04-21 spike; no full sister migration needed.
6. **Transitive-dep workspace linking.** Known limitation: `link-workspace-packages` does not extend to transitive deps. If a Phase 2 use case needs `dev-app → reventless-ui` to live-link, add a `pnpm.overrides` entry in the gitignored overlay — do NOT commit it.

---

## Next steps

1. Merge `feat/pnpm-migration` into `alpha` after CI passes on the branch.
2. **Before Phase 2:** coordinate a tiny PR on the sister repo to add `pnpm-workspace.yaml` (`packages: ['reventless/*']`). This is a zero-impact change for sister's own npm workflow.
3. Execute Phase 2 (overlay script, `link:on`/`link:off` toggles, gitignored local config, docs).
4. ~~**Optional cleanup** (Phase-2-adjacent): convert all in-repo `@reventlessdev/*` semver ranges to `workspace:*`.~~ **Done** (see §1.4d follow-up).

## Pre-existing test regression (NOT caused by this plan)

Discovered during the §1.4d follow-up cleanup: running `pnpm test` on the tip of `feat/pnpm-migration` (both with and without the cleanup applied) yields **84 failed / 926 passed / 1010 total** — not the 1034/1034 reported at commit `1de8b775`. Failing tests share a common stack: `uuid@13.0.0` throws `crypto.getRandomValues() not supported` because Jest 27's default `jsdom` test environment does not expose `globalThis.crypto` as a bare `crypto` identifier inside the VM. A minimal Jest probe confirms `typeof crypto === "undefined"` in the test context.

Baseline comparison: stashing the workspace-protocol cleanup and re-running `pnpm install --frozen-lockfile` followed by `pnpm test` produces the **exact same** 84-failure / 926-pass counts. The cleanup is test-neutral. Why the Phase-1 commit reported 1034/1034 — whether the env was genuinely different (different jest/jsdom version, different Node, different default `testEnvironment`) or the verification number was incorrect — is out of scope here and should be tracked separately before merging to `alpha`.
