# Plan: Migrate reventless-core to pnpm (+ cross-repo dev linking)

**Date:** 2026-04-21

## Why this plan exists

Cross-repo linking with npm has produced repeated fires: `npm install` wipes hand-crafted symlinks, `file:` overrides resolve relative to the consuming workspace rather than the root (producing broken paths), and ReScript's compiler panics when its module walker traverses a symlinked package's ancestor `node_modules/` and finds duplicate deps.

pnpm is chosen because:

- First-class support for cross-package linking (`workspace:*` protocol).
- Strict hoisting — the symlinked package's deps get resolved into pnpm's content-addressable store, not left in a competing sibling tree. This eliminates the ReScript duplicate-package panic.
- A single config knob (the presence of a local overlay file) toggles between "link mode" (sibling repo as live source) and "release mode" (registry version) — no edits to committed files.
- Stable workspace semantics across versions; npm's hoisting behaviour has shifted multiple times.

Alternatives considered and rejected: plain `npm link` (survives install but still hits the ReScript walker issue and has no git-tracked config); npm cross-repo workspaces (not all versions accept `..` in the glob, and switching modes requires editing committed files); Yarn Berry (`portal:` works but PnP has incompatibilities with some tooling; upgrade path weaker than pnpm); Nx/Turborepo/Bazel (massive adoption cost for the small repo count). A local Verdaccio registry remains the fallback if Phase 0 fails — it trades edit-loop speed for full install isolation.

---

## Goal

Replace npm with pnpm as the monorepo's package manager, and establish a clean pattern for linking the sister repo `reventless-ui` into local development builds without breaking ReScript or CI.

### What this unlocks when done

- Edits in a sibling `reventless-ui` working copy appear instantly in core's example builds — no `npm publish` cycle, no manual symlink hygiene.
- CI and fresh clones install from the registry unchanged — no per-developer setup required.
- Switching between "link mode" (live sibling repo) and "release mode" (registry version) is toggled by the presence of one gitignored file. No edits to committed `package.json`.
- ReScript compiler stops hitting the "Duplicated package" panic caused by cross-repo symlink traversal.

---

## Prerequisites

- pnpm installed (`corepack enable && corepack prepare pnpm@latest --activate`) on the dev machine. No repo-wide install yet.
- A clean branch off `alpha`. This plan is invasive — do not mix with unrelated work.
- Time budget: Phase 0 is a 1-hour spike. Phases 1–3 are 1–2 focused days.

---

## Phase 0 — Spike to validate pnpm + ReScript

**Why first:** the key assumption is that pnpm's strict hoisting fixes ReScript's ancestor-`node_modules` traversal panic. Prove it before committing to the migration. If ReScript still panics with pnpm's linked workspaces, abandon this plan and fall back to Verdaccio.

### 0.1 Throwaway spike branch

Create a short-lived branch `spike/pnpm-rescript`. All spike work happens here — discard on completion.

### 0.2 Smoke install

1. `corepack enable && corepack prepare pnpm@latest --activate`
2. In core root: `rm -rf node_modules package-lock.json`
3. Create minimal `pnpm-workspace.yaml`:
   ```yaml
   packages:
     - 'packages/*'
     - 'rescript/*'
     - 'reventless/*'
     - 'examples/**'
   ```
4. `pnpm install` — verify it completes without errors.
5. `pnpm run build` from root — verify all four ReScript builds succeed.

### 0.3 Cross-repo link test

1. In a sibling working copy of `reventless-ui`, add `pnpm-workspace.yaml` so its package is a valid pnpm workspace.
2. In core, create `pnpm-workspace.local.yaml` with the sister path:
   ```yaml
   packages:
     - '../reventless-ui/reventless/reventless-ui'
   ```
3. `pnpm install` (pnpm reads both files by default if supported; otherwise merge manually or use a shared-workspace flag).
4. Verify `node_modules/@reventlessdev/reventless-ui` resolves to the sister repo.
5. **Critical:** in `examples/online-shop-hybrid/platform-in-memory`, run `pnpm run build`. If ReScript panics with "Duplicated package" — the migration fails and the fallback is Verdaccio.

### Checklist

```
Phase 0 (spike)
  [ ] 0.1  Branch spike/pnpm-rescript
  [ ] 0.2  pnpm install succeeds on committed workspaces
  [ ]      Verify: pnpm run build passes on all four example builds, zero warnings
  [ ] 0.3  Link sister reventless-ui via pnpm-workspace.local.yaml overlay
  [ ]      Verify: rescript build of catalog-ui (or any example consuming
           @reventlessdev/reventless-ui) succeeds with NO "Duplicated package" errors
  [ ]      Verify: edits to a sister .res file appear in core's compiled output
           without republishing
```

**Exit criteria:** Phase 0 passes all checklist items. If ReScript panics anywhere, record findings in this plan under a new "Phase 0 failure" section and stop — this plan is not viable; open a Verdaccio fallback plan instead.

---

## Phase 1 — Migrate core to pnpm

Assuming Phase 0 passed, execute the migration on a clean branch off `alpha`.

### 1.1 Install pnpm, convert lockfile

1. `corepack enable && corepack prepare pnpm@latest --activate`.
2. At core root: `rm -rf node_modules`.
3. `pnpm import` — converts `package-lock.json` into `pnpm-lock.yaml` (lossy on edge cases; verify deltas by inspecting resolved versions of a sample of packages).
4. Delete `package-lock.json`.
5. Add `pnpm-lock.yaml` to git.

### 1.2 Replace workspace config

Remove `"workspaces": [...]` from root `package.json`. Create `pnpm-workspace.yaml` with identical globs:

```yaml
packages:
  - 'packages/*'
  - 'rescript/*'
  - 'reventless/*'
  - 'examples/**'
```

Delete the nested `examples/online-shop-hybrid/platform-in-memory/reventless-ui` symlink if it exists — it is a cross-repo hack that conflicts with clean workspace resolution.

### 1.3 Update scripts

Replace npm-specific script invocations in root and workspace `package.json`s:

| npm | pnpm |
|---|---|
| `npm install` | `pnpm install` |
| `npm ci` | `pnpm install --frozen-lockfile` |
| `npm run build -w <pkg>` | `pnpm --filter <pkg> run build` |
| `npm run build --workspaces --if-present` | `pnpm -r run build` (recursive) |
| `npm --prefix path run x` | `pnpm --filter ./path run x` |

Grep every `package.json` for `npm ` invocations and convert. Common scripts: `dev:*`, `build`, `test`, `clean`.

### 1.4 Overrides migration

pnpm reads `pnpm.overrides` in root `package.json` (not `overrides`). Move:

```json
"pnpm": {
  "overrides": {
    "@docusaurus/theme-common": "3.9.2",
    "graphql": "^16.0.0"
  }
}
```

Drop `"overrides"` (npm-style).

### 1.5 Strict hoisting guard

Verify no package in the repo relies on a phantom dep (a dep used at runtime but not declared in its own `package.json`). pnpm refuses these by default. Remediation: add the missing dep to the relying package's `dependencies`. Run `pnpm install` and fix errors until clean.

### 1.6 Update CI

Replace in CI config:

```yaml
# before
- run: npm ci
- run: npm run build

# after
- run: corepack enable
- uses: pnpm/action-setup@v4
  with:
    version: 9
- run: pnpm install --frozen-lockfile
- run: pnpm run build
```

### 1.7 Verify

- `pnpm install` from scratch (delete `node_modules`) completes clean.
- `pnpm run build` from root — zero warnings (see `.claude/rules/conventions.md`).
- `pnpm test` — all tests pass.
- Every script named in root `package.json` runs without error.
- Lerna publish (if used) still works — pnpm and lerna coexist; verify with `pnpm exec lerna publish --dry-run`.

### Checklist

```
Phase 1 (core migration)
  [ ] 1.1  pnpm import; commit pnpm-lock.yaml; delete package-lock.json
  [ ] 1.2  pnpm-workspace.yaml replaces workspaces array; delete nested
           cross-repo symlink if present
  [ ] 1.3  All npm invocations in package.json scripts converted to pnpm
  [ ] 1.4  overrides → pnpm.overrides
  [ ] 1.5  Phantom-dep remediation: every used dep declared
  [ ] 1.6  CI updated to use pnpm/action-setup + frozen-lockfile
  [ ]      Verify: pnpm install from scratch succeeds
  [ ]      Verify: pnpm run build (all four example builds) — zero warnings
  [ ]      Verify: pnpm test — all suites pass
  [ ]      Verify: lerna exec compatible (pnpm exec lerna ... succeeds)
```

---

## Phase 2 — Cross-repo linking via local overlay

The mechanism: pnpm supports reading workspace packages from a file whose presence indicates "link mode." Committed config covers release mode; a gitignored file adds the sibling repo for link mode.

### 2.1 Add the overlay mechanism

pnpm 9+ supports `pnpm-workspace.yaml`. There is no native "overlay" feature; the clean pattern is:

1. Create `pnpm-workspace.yaml.template` (committed) with the release-mode-only entries — identical to what's in `pnpm-workspace.yaml`.
2. Developers can replace `pnpm-workspace.yaml` locally with a variant that adds sibling paths. A gitignored copy is the source of truth in link mode.
3. Add `pnpm-workspace.yaml` to `.gitignore` **only** if teams agree every developer owns the file. Otherwise keep it committed with in-repo paths, and provide a helper script that swaps in an overlay copy.

Alternative (cleaner): pnpm's `packages-relative-to-configured-workspaces` plus two files merged via environment variable:

```yaml
# pnpm-workspace.yaml (committed) — release mode workspaces only
packages:
  - 'packages/*'
  - 'rescript/*'
  - 'reventless/*'
  - 'examples/**'
```

```yaml
# pnpm-workspace.local.yaml (gitignored) — link mode additions
packages:
  - '../reventless-ui/reventless/reventless-ui'
```

Because pnpm does not auto-merge these, provide a small script:

```json
// root package.json
"scripts": {
  "link:on":  "cat pnpm-workspace.yaml pnpm-workspace.local.yaml > pnpm-workspace.merged.yaml && mv pnpm-workspace.merged.yaml pnpm-workspace.yaml && pnpm install",
  "link:off": "git checkout pnpm-workspace.yaml && pnpm install"
}
```

Committed file is the source of truth for release mode. `link:on` augments it; `link:off` restores it. Both trigger `pnpm install` to realign `node_modules/`.

### 2.2 Gitignore

Add to `.gitignore`:
```
pnpm-workspace.local.yaml
pnpm-workspace.merged.yaml
```

### 2.3 Declare cross-repo deps with `workspace:*`

In every consumer package that depends on `@reventlessdev/reventless-ui`:

```json
"dependencies": {
  "@reventlessdev/reventless-ui": "workspace:*"
}
```

- In link mode (sibling path in workspace): resolves to the local working copy.
- In release mode (no sibling): pnpm resolves `workspace:*` to the registry version declared via the lockfile. In pure release mode (CI with only registry access), use `pnpm install --no-frozen-lockfile` or specify `^<version>` explicitly.

**Gotcha:** `workspace:*` requires the workspace to be present at install time. For fresh release-mode clones, either (a) commit a release-mode lockfile, or (b) rewrite `workspace:*` to `^<version>` at publish via `pnpm publish --workspace-protocol`.

### 2.4 Document the workflow

Create `docs/guides/cross-repo-dev-linking.md`:

```
To enable live-edit of reventless-ui from this repo:

  1. cp pnpm-workspace.local.yaml.example pnpm-workspace.local.yaml
  2. pnpm run link:on
  3. Edits in ../reventless-ui/reventless/reventless-ui/src/ appear
     instantly in core's compiled output.

To return to registry mode:

  pnpm run link:off
```

Ship a `pnpm-workspace.local.yaml.example` file (committed, so teammates copy it) that documents the expected structure.

### Checklist

```
Phase 2 (cross-repo linking)
  [ ] 2.1  link:on and link:off scripts wired in root package.json
  [ ] 2.2  pnpm-workspace.local.yaml and .merged.yaml in .gitignore
  [ ] 2.3  @reventlessdev/reventless-ui declared as workspace:* in
           every consumer package
  [ ] 2.4  Write docs/guides/cross-repo-dev-linking.md
  [ ] 2.5  Ship pnpm-workspace.local.yaml.example with expected shape
  [ ]      Verify (link mode): link:on → edits to sibling .res file
           reflect in core's compiled output after rescript rebuild
  [ ]      Verify (release mode): link:off → pnpm install resolves
           @reventlessdev/reventless-ui from registry
  [ ]      Verify (toggle): link:on → link:off → link:on works cleanly,
           no leftover state
```

---

## Phase 3 — Sister repo compatibility

For link mode to work, `reventless-ui` must also be a pnpm repo (or at minimum expose itself as a valid pnpm workspace — which requires `pnpm-workspace.yaml` at its root). If the sister repo is still on npm:

- **Option A:** migrate the sister repo to pnpm (separate plan; coordinate with sister-repo owners).
- **Option B:** run a compat shim — pnpm can consume npm-installed packages as workspaces if they have correctly-declared `package.json`. Validate in Phase 0.

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

If Phase 1 or 2 fails at verification:

1. `git checkout` the branch.
2. `rm -rf node_modules pnpm-lock.yaml pnpm-workspace.yaml`.
3. Restore `package-lock.json` from the pre-migration commit on `alpha`.
4. `npm install`.
5. Document the failure mode in this plan under a new "Failed attempts" section. Decide between retrying with pnpm at a different version, or pivoting to Verdaccio.

---

## Risks

1. **pnpm lockfile drift** during `pnpm import` — some npm resolutions may not translate cleanly (e.g. `file:` specs, github: refs). Mitigation: diff the resolved versions of a 20-package sample before committing.
2. **Phantom deps** (Phase 1.5) — common in older workspaces. Expect to find 3–10 missing declarations. Each is a one-line fix but takes time.
3. **CI environment** — ensure pnpm is available in whatever CI tool we use. `pnpm/action-setup@v4` for GitHub Actions; equivalent for others.
4. **Lerna publish flow** — verify lerna + pnpm compatibility before merging. Lerna has first-class pnpm support in v7+ but edge cases exist around `publishConfig`.
5. **rescript-relay compiler** — if ReScript's `relay-runtime` dep is hoisted differently, rescript-relay-compiler may fail to find it. Validate during Phase 0.
6. **`workspace:*` publishing** — when we `pnpm publish`, `workspace:*` refs must be rewritten to concrete versions. pnpm does this with `--workspace-protocol` but misconfiguration publishes broken package.json.

---

## What this plan does NOT cover

- Migrating the sister `reventless-ui` repo itself (Phase 3 is only the compatibility check — a full sister migration is a separate effort).
- Migrating any other sibling repos that may depend on core.
- Setting up a local Verdaccio registry as an alternative fallback (separate plan if Phase 0 fails).
- Changes to the lerna release flow beyond ensuring it still works.

---

## Open questions

1. Which pnpm version to pin? 9.x is stable, 10.x is latest. Start with 9 for conservatism.
2. Do we commit `pnpm-workspace.yaml` or require developers to copy from a template? Recommendation: commit with release-mode paths; overlay is gitignored.
3. Should `workspace:*` apply to all cross-package deps in the monorepo (even in-repo), or only cross-repo? Recommendation: all in-repo deps use `workspace:*`; cross-repo uses `workspace:*` too, but only resolves when overlay is active.

---

## Decision needed before executing

This plan is approved for the 1-hour Phase 0 spike only. Phases 1–3 execute only after Phase 0 passes and the findings justify the migration cost. If Phase 0 fails, no further work on this plan — the fallback is a separate Verdaccio plan.
