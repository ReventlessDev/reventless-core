# Plan: Migrate reventless-core to pnpm (+ cross-repo dev linking)

**Date (v1):** 2026-04-21
**Date (v2 rewrite, post-Phase-0):** 2026-04-21

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

Replace npm with pnpm as the monorepo's package manager, using `node-linker=hoisted` for ReScript compatibility, and establish a clean overlay pattern for linking the sister repo `reventless-ui` into local development builds without breaking the compiler or CI.

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
Phase 1 (core migration)
  [ ] 1.1  pnpm import; commit pnpm-lock.yaml; delete package-lock.json
  [ ] 1.2  .npmrc has node-linker=hoisted and enable-pre-post-scripts=true
  [ ] 1.3  pnpm-workspace.yaml created with packages + onlyBuiltDependencies
  [ ] 1.4a Root package.json declares all 20 root-rescript.json deps as workspace:*
  [ ] 1.4b Each of 20 identified workspaces declares its own rescript.json deps
  [ ] 1.4c Build-iteration loop converges with zero "try_package_path" errors
  [ ] 1.5  overrides → pnpm.overrides
  [ ] 1.6  All npm invocations in package.json scripts converted to pnpm
  [ ] 1.7  Verify: fresh pnpm install succeeds
  [ ]      Verify: pnpm run build (all three example platforms) succeeds
  [ ]      Verify: pnpm test — all suites pass
  [ ]      Verify: pnpm exec lerna publish --dry-run succeeds
  [ ]      Document: list of Duplicated-package warnings that remain (should
           be warnings only, not panics)
  [ ] 1.8  CI updated; pnpm/action-setup@v4 with version 10
```

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

The original plan assumed strict-hoisting would clean up the ReScript duplicate-package panic across repos. In hoisted mode, we do not know yet:

- Whether the sister repo's `node_modules/@reventlessdev/*` contents shadow or duplicate core's — must test.
- Whether `rescript.json` in consumers of `@reventlessdev/reventless-ui` needs an entry for cross-repo deps.
- How `generate-plugin` behaves with a linked sibling whose generated files live in a different repo's `src/`.

Budget an extra half-day in Phase 2 for these.

---

## Phase 3 — Sister repo compatibility

For link mode to work, `reventless-ui` must be a valid pnpm workspace target, which requires `pnpm-workspace.yaml` at its root (even if minimal).

- **Option A:** Migrate the sister repo to pnpm fully (separate plan; coordinate with sister-repo owners).
- **Option B:** Add only `pnpm-workspace.yaml` to the sister so it can be consumed as a pnpm workspace while staying on npm for its own development. Needs validation — pnpm must be able to read a workspace that wasn't `pnpm install`-ed.

### Checklist

```
Phase 3 (sister compatibility)
  [ ] 3.1  Verify sister repo works as a pnpm workspace target
           (either natively pnpm or via compat shim)
  [ ] 3.2  If migration needed: file a separate plan/issue for sister repo
  [ ]      Verify: link:on → build works end-to-end
```

---

## Rollback

If Phase 1 fails at verification:

1. `git checkout alpha`.
2. `rm -rf node_modules pnpm-lock.yaml pnpm-workspace.yaml`.
3. Restore `.npmrc` to its pre-migration state (remove `node-linker=hoisted`, `enable-pre-post-scripts=true`).
4. `npm install`.
5. Document the failure mode here under a new "Phase 1 failure" section. Decide between retrying with a different pnpm strategy, or pivoting to Verdaccio.

---

## Risks

1. **Phantom-dep iteration loop (§1.4c).** Each failed build reveals one missing declaration at a time. Budget accordingly; don't treat it as a one-shot fix.
2. **pnpm build-script approval flakiness.** `sury-ppx` postinstall didn't run reliably during the spike. Mitigation: document manual re-run; consider a root postinstall that `chmod +x`'s known binaries.
3. **`pnpm import` lockfile drift.** npm's `file:` specs, `github:` refs, and peer-dep hoisting behave differently. Mitigation: diff resolved versions on a 20-package sample before committing.
4. **Lerna + pnpm.** Lerna v7+ has first-class pnpm support but edge cases exist around `publishConfig` and workspace-protocol publishing. Verify with `pnpm exec lerna publish --dry-run`.
5. **`Main.res` uiBundleUrl error surfaced during spike.** May be pre-existing on `alpha`; verify with plain npm before blaming pnpm. If real, fix independently of this migration.
6. **rescript-relay compiler.** Possibly sensitive to node_modules layout. Validate during Phase 1.7.
7. **`workspace:*` publishing.** Mis-configured `--workspace-protocol` flag publishes broken package.json files. Always `pnpm publish --dry-run` before real publish.
8. **Warnings vs panics.** We are accepting ongoing `Duplicated package` warnings from ReScript. If any future change promotes these to hard errors, the plan's viability regresses.

---

## What this plan does NOT cover

- Full migration of sister `reventless-ui` repo (Phase 3 is compat check only).
- Migrating any other sibling repos that may depend on core.
- Setting up a local Verdaccio registry as an alternative fallback (separate plan if this one fails).
- Changes to the Lerna release flow beyond verifying it still works.
- Moving off `node-linker=hoisted` to pnpm's isolated default — out of scope until ReScript's resolver changes or the monorepo's phantom-dep surface is reduced.

---

## Open questions

1. **pnpm version pin.** 10.x is current; 9.x is stable. Phase 0 used 10.33. Recommendation: pin at 10.x via `packageManager` field in root `package.json`.
2. **Monorepo-wide prebuild.** Today each plugin has its own `prebuild: npm run generate`. With `enable-pre-post-scripts=true` this continues to work, but consider whether a single top-level `generate-all` task would be cleaner.
3. **Duplicated-package warnings.** Should we suppress them (via rescript warning flags) or leave them visible as topology signal? Recommendation: leave visible until §1.4c converges; then reassess.
4. **`workspace:*` everywhere, or only cross-repo?** Recommendation: use `workspace:*` for all in-repo deps; it's the pnpm-native pattern and makes the dep graph explicit in the lockfile.
5. **Sister repo migration path.** Full pnpm migration vs compat-shim is a separate decision; gather sister-repo-owner input before Phase 3.

---

## Decision needed before executing Phase 1

This rewritten plan reflects actual Phase 0 findings and sets realistic scope for a 2–3 day Phase 1 effort. The key shift from v1: **pnpm in `node-linker=hoisted` mode, not strict hoisting.** This changes the value proposition from "fix duplicate-package panic" to "explicit workspace:* deps + overlay cross-repo linking on top of a known-good hoisted layout."

Explicit approval required before starting Phase 1. If the effort feels disproportionate, the Verdaccio fallback is the next thing to evaluate.
