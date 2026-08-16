# Registry and Token Configuration

Reventless packages are published to the **public npm registry** (npmjs.com) under
the `@reventlessdev` scope. This guide covers how to install them (no token needed)
and how maintainers publish.

## Installing Packages

All `@reventlessdev/*` packages are **public on npmjs** — installing them requires
**no authentication token**:

```bash
pnpm install @reventlessdev/reventless-core
# or pnpm add / yarn add — all work anonymously
```

A fresh clone of this repo installs with a plain `pnpm install`; there is nothing to
configure for read access.

## `.npmrc` Configuration

`registry.npmjs.org` is the default registry, so no scope routing is required. The
root `.npmrc` only carries the auth line used by **CI when publishing**:

```ini
registry=https://registry.npmjs.org

# Used by CI publish only; unset locally (installs are anonymous).
//registry.npmjs.org/:_authToken=${NPM_TOKEN}
```

> Local builds run without `NPM_TOKEN` set; pnpm prints a harmless
> `Failed to replace env in config: ${NPM_TOKEN}` warning that can be ignored.

## Publishing (maintainers / CI)

Publishing is automated in CI (`release.yml`, `publish-ppx.yml`) and authenticated
with an **`NPM_TOKEN`** — an npm automation/granular token scoped to the
`@reventlessdev` org, stored as a GitHub Actions secret. Scoped packages are
published with `--access public` (configured in `lerna.json`).

## Token Summary

| Variable | Where | Purpose |
|---|---|---|
| _(none)_ | — | Installing public `@reventlessdev/*` packages needs no token |
| `NPM_TOKEN` | CI secret | Publishing to npmjs (maintainers / GitHub Actions only) |
