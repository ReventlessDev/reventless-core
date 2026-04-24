# pnpm in this repo

This repo uses **pnpm 10** as its package manager. This guide covers the
practical differences from npm — command translations, repo-specific
settings, and the gotchas most likely to trip up someone used to npm.

The migration rationale and step-by-step record lives in
[docs/plans/done/pnpm-migration.md](../plans/done/pnpm-migration.md).
Cross-repo dev linking is documented separately in
[cross-repo-dev-linking.md](./cross-repo-dev-linking.md).

## Why pnpm

- **`workspace:*` protocol** declares internal deps explicitly, so the
  lockfile and `package.json` show real workspace topology instead of
  hoped-for hoisting. `pnpm publish` rewrites `workspace:*` to concrete
  semver at publish time.
- **Stable hoisting rules.** npm's layout has shifted multiple times and
  made cross-repo symlinking unreliable (`file:` paths broke, hand-crafted
  symlinks got wiped by `npm install`).
- **Overlay-friendly topology.** A gitignored overlay can add sibling repos
  as workspace packages without editing committed files — see the link-mode
  tooling in the cross-repo guide.

## One-time setup

```bash
corepack enable
corepack prepare pnpm@10 --activate
```

Use Node 22.17.1 (see `.node-version`). The `packageManager` field in
`package.json` pins pnpm to `10.33.0`.

## Command translation

| npm | pnpm |
|---|---|
| `npm install` | `pnpm install` |
| `npm ci` | `pnpm install --frozen-lockfile` |
| `npm install <pkg>` | `pnpm add <pkg>` |
| `npm install -D <pkg>` | `pnpm add -D <pkg>` |
| `npm uninstall <pkg>` | `pnpm remove <pkg>` |
| `npm run <script>` | `pnpm run <script>` (or `pnpm <script>`) |
| `npm run build --workspaces` | `pnpm -r run build` |
| `npm run build -w <pkg>` | `pnpm --filter <pkg> run build` |
| `npm --prefix path run x` | `pnpm --filter ./path run x` |
| `npx <bin>` | `pnpm exec <bin>` (or `pnpm dlx` for one-shots) |

Scripts inside `package.json` have been converted repo-wide. If you find a
script still calling `npm run …`, that's a bug — file it.

## Lockfile

- `package-lock.json` is gone. `pnpm-lock.yaml` replaces it.
- Both `pnpm install` and `pnpm install --frozen-lockfile` are safe to run
  locally. CI uses the frozen form.
- Commit `pnpm-lock.yaml` with every change to `package.json`.

## Workspace configuration

- The tracked source of truth is `pnpm-workspace.base.yaml`. Root
  `pnpm-workspace.yaml` (gitignored) is either a symlink to it or a merged
  link-mode file; see
  [cross-repo-dev-linking.md](./cross-repo-dev-linking.md).
  The base file lists workspace globs (`packages/*`, `rescript/*`,
  `reventless/*`, `examples/**`) and `onlyBuiltDependencies`.
- The root `package.json` no longer has a `"workspaces"` key — that moved
  to the workspace file.
- Internal cross-workspace deps are declared as `"workspace:*"` in
  individual `package.json` files. When publishing, pnpm rewrites these to
  the resolved semver version in the tarball.

## Hoisted layout (non-default)

`.npmrc` sets:

```
node-linker=hoisted
enable-pre-post-scripts=true
```

- `node-linker=hoisted` produces an npm-like flat `node_modules` layout.
  ReScript's node-module walker and the monorepo's phantom-dep surface
  need this — pnpm's default isolated layout is not viable here.
- `enable-pre-post-scripts=true` restores auto-execution of `prebuild` /
  `postbuild` hooks, which the `generate-plugin` step relies on. pnpm 10
  disabled this by default.

A side effect of hoisted mode is that pnpm may still nest some workspace
deps under `<pkg>/node_modules/…`. This surfaces as `Duplicated package`
warnings from ReScript. Three such warnings are currently accepted
(documented in the migration plan, §1.7a).

## Postinstall build-script approval

pnpm 10 blocks postinstall scripts by default. The explicit allowlist
lives in `pnpm-workspace.yaml` under `onlyBuiltDependencies`:

```yaml
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

When adding a dep whose install relies on a postinstall script (native
binaries, install-time codegen, etc.), add it here, commit both
`package.json` and `pnpm-workspace.yaml`, and verify with a fresh
`pnpm install` in a scratch directory.

If a postinstall silently fails to run (observed with `sury-ppx` during
the migration spike), invoke it manually:

```bash
cd node_modules/<pkg> && node <postinstall-script>.cjs
```

## Overrides

pnpm reads overrides from `pnpm.overrides` in the root `package.json`,
**not** the top-level `overrides` key npm uses:

```json
"pnpm": {
  "overrides": {
    "graphql": "^16.0.0"
  }
}
```

Alternatively, `overrides` can go at the top level of `pnpm-workspace.yaml`
— that form is used by the gitignored link-mode overlay.

## Filtering

pnpm's `--filter` targets workspace packages by name, path, or dependency
graph. Most common forms:

```bash
# by name
pnpm --filter @reventlessdev/reventless-core run build

# by path (relative)
pnpm --filter ./reventless/reventless-core run build

# by directory glob
pnpm --filter './examples/**' run build

# all workspaces
pnpm -r run build
```

## CI

Workflows use `pnpm/action-setup@v4` with `version: 10` and run
`pnpm install --frozen-lockfile`. The `.npmrc` and `pnpm-workspace.yaml`
settings above are picked up automatically.

## Fresh clone / full reset

```bash
# fresh clone
git clone <repo> && cd <repo>
pnpm install --frozen-lockfile
pnpm run build

# nuke-and-reinstall
rm -rf node_modules */*/node_modules
pnpm install
```

`pnpm-lock.yaml` is authoritative; re-running `pnpm install` without it
is not a supported recovery path.

## Publishing

Lerna v8.2.4 drives releases with `npmClient: pnpm` in `lerna.json`.
Publishing rewrites `workspace:*` → concrete semver in the tarball's
`package.json`. Verify before every release:

```bash
pnpm --filter <pkg> pack --pack-destination /tmp/inspect
tar xzf /tmp/inspect/<pkg>-<version>.tgz -C /tmp/inspect
cat /tmp/inspect/package/package.json | jq .dependencies
```

The workspace-protocol entries must all be concrete ranges in the packed
output.

## Cross-repo dev linking

Separate workflow — see [cross-repo-dev-linking.md](./cross-repo-dev-linking.md).
Summary: a gitignored `pnpm-workspace.local.yaml` adds sibling repo paths to
the workspace; `pnpm link:on` / `link:off` toggle between link mode (sibling
is live source) and release mode (registry version). Because
`pnpm-workspace.yaml` itself is gitignored — a symlink to
`pnpm-workspace.base.yaml` in release mode, a regular merged file in link
mode — toggling never dirties a tracked file.

## Common gotchas

- **`npm install` instead of `pnpm install`** leaves `package-lock.json`
  behind and confuses the layout. Delete any accidentally-created
  `package-lock.json`.
- **`workspace:*` in a published dep** means you forgot to publish via
  pnpm's workspace-protocol rewrite. Check the packed tarball.
- **Missing phantom deps.** If ReScript or a bin references a package
  that's not in any `package.json`, pnpm won't symlink it. Add it as a
  `workspace:*` or regular dep to the nearest consumer.
- **`pnpm rebuild` doesn't always re-run postinstall scripts.** For a
  clean slate, remove the affected `node_modules/<pkg>` and reinstall.
- **Duplicated-package warnings** from ReScript are hoisting artifacts,
  not errors. The migration plan §1.7a tracks the accepted set; if a new
  one appears, check whether the offending dep range should be
  `workspace:*`.
- **`pnpm-workspace.yaml` missing after clone.** It's gitignored; run
  `node scripts/workspace-setup.mjs` once to create the symlink to
  `pnpm-workspace.base.yaml`. See the cross-repo guide for details.
