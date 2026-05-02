# Plan: Replace workspace overlay with `pnpm.overrides` link protocol

**Status: ABANDONED (2026-05-03) — DO NOT RE-ATTEMPT.**

Phase 0 spike was run on 2026-05-02 in the sibling business repo and
failed. ReScript's package-tree walker resolves `link:` symlinks to the
sibling source directory and walks **upward** from there looking for
transitive deps. For deep packages like `@reventlessdev/reventless-core`
(which pulls in `sury`, `@glennsl/rescript-jest`,
`rescript-pulumi-pulumi`, etc.), the walker lands in core's own
`node_modules` and cannot reconcile against the consumer's tree,
producing fatal `try_package_path: upward traversal did not find 'sury'`
errors. No pnpm flag, override protocol (`link:`/`file:`/`portal:`),
or node-linker setting fixes this.

**The chosen path forward (2026-05-03): keep the existing overlay
system.** The `apply-workspace-overlay.mjs` + `restore-workspace-base.mjs`
+ `symlink-overlay-deps.mjs` (Phase 2.5, shipped 2026-05-01) machinery
in this repo is the proven solution. The recurring CI fragility (the
gitignored runtime workspace file going missing in fresh checkouts) is
addressed by ensuring every CI workflow runs `node
scripts/workspace-setup.mjs` before `pnpm install`, plus removing
silent-swallow patterns (`2>/dev/null || echo "[]"`) on lerna/pnpm
output (the second was applied to `release.yml` on 2026-05-03).

**Sibling plans (also rejected):**
[reventless-ui](../../../../reventless-ui/docs/plans/rejected/replace-workspace-overlay-with-link-protocol.md)
and
[private-consumer-repo](../../../../../private-consumer/private-consumer-repo/docs/plans/rejected/replace-workspace-overlay-with-link-protocol.md).
business has been rolled back to the overlay system. ui's partial
execution of Step 1 (tracked `pnpm-workspace.yaml`) happens to be
benign because ui's only cross-repo dep is a leaf binding
(`rescript-moment`), but the broader generalization the plan claimed
does not hold.

## Why this plan exists

The cross-repo dev pattern established in
[pnpm-migration.md](pnpm-migration.md) Phase 2 has shipped three times
in ten days and broken three different ways:

1. Hand-crafted symlinks wiped by `pnpm install` → solved by
   `link:on` script.
2. Overlaid sibling packages installed as **copies** under hoisted
   layout, producing duplicate `.cmi` and "inconsistent assumptions"
   build errors → solved today by
   [overlay-symlink-sibling-deps.md](overlay-symlink-sibling-deps.md)
   shipping `scripts/symlink-overlay-deps.mjs`.
3. The runtime `pnpm-workspace.yaml` is **gitignored**, so any fresh
   checkout (CI, dependabot, new dev machine) silently sees no
   workspace. Discovered tonight in the sister
   `reventless-ui` repo: lerna failed with `ENOENT No
   pnpm-workspace.yaml found`, the release workflow swallowed it, and
   no packages were published.

Each iteration layers more machinery on the same indirection: the file
pnpm/lerna read (`pnpm-workspace.yaml`) is not the file git tracks.
This plan removes the indirection and replaces the workspace-overlay
mechanism with `pnpm.overrides` using pnpm's `link:` protocol.

## What changes

### 1. Track `pnpm-workspace.yaml` directly

- Move all content from `pnpm-workspace.base.yaml` into
  `pnpm-workspace.yaml` and commit it.
- Delete `pnpm-workspace.base.yaml` and `pnpm-workspace.local.yaml.example`.
- In `.gitignore`, remove the `pnpm-workspace.yaml` and
  `pnpm-workspace.local.yaml` entries.

After this step, fresh clones and CI just work — no setup ritual.

### 2. Use `pnpm.overrides` + `link:` for cross-repo dev

In place of overlaying sibling repos into `pnpm-workspace.yaml`,
redirect the named deps via `pnpm.overrides` in this repo's `package.json`:

```json
"pnpm": {
  "overrides": {
    "@reventlessdev/reventless-ui":     "link:../reventless-ui/reventless/reventless-ui",
    "@reventlessdev/reventless-routes": "link:../reventless-ui/reventless/reventless-routes"
  }
}
```

`link:` is pnpm's symlink protocol — installs as a symlink under
`node_modules/<name>`, no copy. **This obsoletes Phase 2.5 entirely**
([overlay-symlink-sibling-deps.md](overlay-symlink-sibling-deps.md),
shipped today). The duplicate-`.cmi` problem `symlink-overlay-deps.mjs`
exists to fix does not arise when the dep arrives as a symlink in the
first place.

It also subsumes the transitive-linking workaround documented in
pnpm-migration.md §"Unknowns still to resolve in Phase 2" and §Open
question 6: `pnpm.overrides` applies globally to the install graph, so
a transitive consumer (e.g. an already-published intermediate that
depends on the sister) resolves to the linked version automatically.

### 3. Replace the link scripts

Delete:

- `scripts/apply-workspace-overlay.mjs`
- `scripts/restore-workspace-base.mjs`
- `scripts/symlink-overlay-deps.mjs` (just shipped — see below)
- any sibling helpers (`workspace-link-status.mjs`, `workspace-setup.mjs`)

Add `scripts/cross-repo-link.mjs` with `--on` / `--off` / `--status`:

- Reads a gitignored `cross-repo-link.config.json` mapping
  `<package-name> → <sibling-relative-path>`.
- `--on`: writes the mapping into `package.json`'s `pnpm.overrides`,
  runs `git update-index --skip-worktree package.json`, then
  `pnpm install`.
- `--off`: runs `git update-index --no-skip-worktree package.json`,
  `git checkout -- package.json`, then `pnpm install`.
- `--status`: reports skip-worktree state and current overrides.

`--skip-worktree` keeps the working tree clean: local link state is
invisible to git and cannot be accidentally committed. CI never runs
the script and never sees the overrides.

Update `package.json` scripts:

```json
"link:on":     "node ./scripts/cross-repo-link.mjs --on",
"link:off":    "node ./scripts/cross-repo-link.mjs --off",
"link:status": "node ./scripts/cross-repo-link.mjs --status"
```

### 4. CI fix

In `.github/workflows/release.yml` (and any other workflow that pipes
lerna or pnpm output to `/dev/null`):

- Drop `2>/dev/null || echo "[]"` from the change-detection step.
  Errors must surface, not silently downgrade to "no changes."
- No workspace-restoration step needed once `pnpm-workspace.yaml` is
  tracked.

Verify against this repo's CI workflows even though tonight's failure
was on the sister side — the same shape of risk exists here.

## Per-repo specifics

This repo:

- Cross-repo links *into*: `reventless-ui` (when developing core
  changes that exercise the UI). The default
  `cross-repo-link.config.json.example` lists the current set, taken
  from [pnpm-workspace.local.yaml.example](../../pnpm-workspace.local.yaml.example).
- Consumed by: `reventless-ui` (ui's core deps) and
  `private-consumer-repo` (business's core deps).

Special: this repo just shipped
[overlay-symlink-sibling-deps.md](overlay-symlink-sibling-deps.md)
(2026-05-01). That entire plan is retired by this one. The
`scripts/symlink-overlay-deps.mjs` script and its install-pipeline
wiring (`apply-overlay && pnpm install && symlink-overlay-deps`) are
deleted as part of step 3 above. Mark
[overlay-symlink-sibling-deps.md](overlay-symlink-sibling-deps.md) as
"Superseded by replace-workspace-overlay-with-link-protocol.md" and
move it to `docs/plans/done/` with that note in its status line.

## Phase 0 — spike before commit (half a day)

The main unknown is ReScript's phantom-dep walk under hoisted layout
when sibling deps are reached via a `link:` symlink rather than being
hoisted into the consumer's `node_modules`. Before deleting any
existing scripts:

1. Branch off `alpha`.
2. Add a single `pnpm.overrides` entry pointing at one ui package
   (e.g. `@reventlessdev/reventless-ui`).
3. `pnpm install` and `pnpm run build` for the example platforms that
   exercise the linked package. Confirm: no `Duplicated package`
   warnings; no `inconsistent assumptions over interface S`;
   `readlink node_modules/@reventlessdev/reventless-ui` resolves to
   the sibling.
4. Edit a file in the sibling's `src/` and rebuild here — verify the
   change reaches the compiled output without intermediate steps.

If the spike reveals an unworkable ReScript interaction, abandon this
plan and treat tonight's CI failure with the smaller fix in the
deferred-options section.

## Acceptance

- `git clone <repo> && pnpm install --frozen-lockfile && pnpm run
  build` succeeds with zero manual setup.
- `pnpm link:on` after editing `cross-repo-link.config.json` produces
  symlinks at `node_modules/<name>` for each entry.
- `pnpm run build` from this repo with link mode active emits zero
  duplicate-package warnings for overridden names and zero
  `inconsistent assumptions over interface S` errors after the sister
  rebuilds independently.
- `pnpm link:off` returns the working tree to a clean state (`git
  status` empty).
- All CI workflows surface lerna/pnpm errors loudly; none can silently
  downgrade to "no changes."

## Sequencing

Independent of the sibling repos. This repo can land first or last.
Until all three repos adopt the same pattern, the link toggle in each
repo behaves slightly differently, which is the inconsistency this
plan exists to end. Plan all three within a short window.

## What this plan retires

- [pnpm-migration.md](pnpm-migration.md) Phase 2 (overlay scripts,
  gitignored runtime workspace file, `link:on`/`link:off` via
  workspace merge) and the §Open question 6 transitive-linking
  workaround. Phase 1 (the npm → pnpm migration itself) stays
  unchanged.
- [overlay-symlink-sibling-deps.md](overlay-symlink-sibling-deps.md)
  in full. Move to `done/` with a "superseded" note.

## Out of scope

- pnpm `catalog:` references. Complementary; track separately.
- Skipping `pnpm clean` in upgrade guides (see business's
  [improve-core-dep-update-workflow.md](../../../../private-consumer/private-consumer-repo/docs/plans/improve-core-dep-update-workflow.md)
  Fix 2).
- Single-root pnpm workspace spanning all three repos. Considered and
  rejected by the same business plan as too invasive.
- Moving off `node-linker=hoisted` (out of scope by pnpm-migration.md
  too — same constraint).

## Deferred / fallback

If Phase 0's spike rules out `link:`-based linking, the minimal "don't
break CI in any repo" fix is two lines per workflow:

1. `ln -sf pnpm-workspace.base.yaml pnpm-workspace.yaml` before
   `pnpm install`.
2. Drop any `2>/dev/null || echo "[]"` swallowers so the next silent
   skip can't happen.

That keeps the existing overlay machinery working and surfaces future
breakage loudly. It does not solve the recurring-iteration problem
this plan exists to solve.
