# Contributing

Guide for getting a development environment running against
`reventless-core`. Covers install, build, test, daily workflow, and
cross-repo linking for developers who also work in a sibling UI repo.

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Node | 22.17.1 | Pinned in [.node-version](https://github.com/ReventlessDev/reventless-core/blob/alpha/.node-version) |
| pnpm | 10 | Installed via corepack |
| Git | Any modern | |

```bash
corepack enable
corepack prepare pnpm@10 --activate
node --version    # should match .node-version
pnpm --version    # should print 10.x
```

### Registry access

`@reventlessdev/*` packages resolve from a configured registry. Set your
auth token up once per machine before running `pnpm install` — see
[Registry and Tokens](registry-and-tokens.md) for the full walk-through,
including the `.npmrc` example and CI environment-variable wiring.

---

## Clone and install

```bash
git clone <repo-url> reventless-core
cd reventless-core
node scripts/workspace-setup.mjs     # one-time: create pnpm-workspace.yaml symlink
pnpm install --frozen-lockfile
```

`pnpm-workspace.yaml` is gitignored; the tracked source of truth is
`pnpm-workspace.base.yaml`. The setup script creates the symlink so pnpm has
a workspace config to read. See
[cross-repo-dev-linking.md](cross-repo-dev-linking.md) for the full mechanism.

`--frozen-lockfile` is the recommended default — it matches CI and catches
accidental lockfile drift. Drop it only when intentionally changing
dependencies.

A fresh clone is in **release mode** by default: all workspace deps resolve
from their locked registry versions.

---

## Build and test

```bash
pnpm run build        # Build everything (root, then plugin platforms)
pnpm test             # Run Jest across all packages
pnpm run clean        # Clean compiled output
```

Per-package commands (from inside any package directory):

```bash
pnpm run build        # rescript build
pnpm run start        # rescript build -w (watch)
pnpm test             # jest
pnpm run dev          # jest --watchAll
```

Filter a single package from root:

```bash
pnpm --filter @reventlessdev/reventless-core run build
pnpm --filter ./reventless/local run test
```

### Compiler warnings

Zero warnings are required before committing. After a build:

```bash
pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"
```

---

## Repo layout

See [CLAUDE.md](https://github.com/ReventlessDev/reventless-core/blob/alpha/CLAUDE.md) for the full package map. At a glance:

| Folder | Purpose |
|---|---|
| `reventless/` | Framework + extension packages |
| `rescript/` | ReScript bindings for JS libraries |
| `examples/` | Example platforms and plugins |
| `packages/` | Build tooling and documentation |

Always place new packages under the correct root folder. Per-folder
conventions are documented in
[.claude/rules/conventions.md](https://github.com/ReventlessDev/reventless-core/blob/alpha/.claude/rules/conventions.md).

---

## Daily workflow

1. Branch off `alpha` (or the branch your maintainer points you to).
2. Make changes, keeping the build green and tests passing.
3. Commit with [Conventional Commits](https://conventionalcommits.org)
   prefixes (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:` …). Dependency
   updates: use `fix(deps):` / `feat(deps):` when the change affects users,
   `chore(deps):` otherwise.
4. Push and open a PR.

Framework-specific conventions (component structure, PPX annotations,
aggregate vs. DCB choice, idempotency) live in
[.claude/rules/](https://github.com/ReventlessDev/reventless-core/tree/alpha/.claude/rules/) and the guides under `docs/guides/`.

---

## Cross-repo development

If you are also working in a sibling UI repo checked out next to this
one, you can optionally switch into **link mode** so local edits there
appear in your core build without a publish cycle:

```bash
pnpm link:status   # show current mode
pnpm link:on       # switch to link mode (sibling is live source)
pnpm link:off      # restore release mode
```

The committed `pnpm-workspace.base.yaml` is the release-mode source of
truth. `pnpm-workspace.yaml` is gitignored — either a symlink to the base
file (release) or a merged file produced from your local
`pnpm-workspace.local.yaml` overlay (link mode). Either mode is safe to
commit in; only run `pnpm link:off` before publishing.

Full mechanism, overlay file format, transitive-dep caveats, and
troubleshooting are in [cross-repo-dev-linking.md](cross-repo-dev-linking.md).

If you don't have a sibling UI checkout, simply stay in release mode —
everything installs from the registry as usual.

---

## Running a local dev server

The local platform exposes a GraphQL backend a UI dev server can
connect to. See [local-dev.md](/tutorials/run-locally) for the full setup,
including the one-command `pnpm run dev:full` variant that runs backend
and UI side by side.

---

## Opening issues and PRs

- **Bug reports and feature requests**: open a GitHub issue against this
  repo. Include the ReScript/package versions you're running and a minimal
  reproduction where possible.
- **Pull requests**: keep them focused; one logical change per PR. Ensure
  `pnpm run build` and `pnpm test` pass locally before pushing. CI runs
  the same commands on every branch.
- **Security issues**: do not file them publicly; contact the maintainers
  directly.

---

## Further reading

- [CLAUDE.md](https://github.com/ReventlessDev/reventless-core/blob/alpha/CLAUDE.md) — top-level project context and conventions
- [pnpm-guide.md](pnpm-guide.md) — npm → pnpm command reference
- [registry-and-tokens.md](registry-and-tokens.md) — auth setup
- [cross-repo-dev-linking.md](cross-repo-dev-linking.md) — link-mode workflow
- [local-dev.md](/tutorials/run-locally) — running a local GraphQL backend
- [platform-and-plugin-guide.md](/app/platform-and-plugin-guide) — how to
  build a new platform or plugin
