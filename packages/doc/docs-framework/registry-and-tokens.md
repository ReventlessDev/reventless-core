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

`registry.npmjs.org` is the default registry, so no scope routing is required, and
the root `.npmrc` carries **no auth line at all**:

```ini
registry=https://registry.npmjs.org
```

Every dependency is public, so installs — local and CI alike — are anonymous and
need no token defined.

:::note Why there is no `_authToken` line
There used to be one, referencing `${NPM_TOKEN}`. It made a credential mandatory
for a job that needed none, and it failed badly when absent: pnpm discards the
**entire** `.npmrc` when a variable it interpolates is undefined, silently taking
`node-linker=hoisted` with it. Locally that surfaced as a warning to ignore; in CI
it left `@pulumi/*` unhoisted and produced `Pulumi SDK has not been installed`
much later, in a different job, for no visible reason.
:::

## Publishing (maintainers / CI)

Publishing is automated in CI (`release.yml`, `publish-ppx.yml`) and authenticated
with an **`NPM_TOKEN`** — an npm automation/granular token scoped to the
`@reventlessdev` org, stored as a GitHub Actions secret. The publish jobs export it
as `NODE_AUTH_TOKEN`, against the `~/.npmrc` that `actions/setup-node` writes from
its `registry-url`, so the credential exists only inside the job that publishes. Scoped packages are
published with `--access public` (configured in `lerna.json`).

## Token Summary

| Variable | Where | Purpose |
|---|---|---|
| _(none)_ | — | Installing public `@reventlessdev/*` packages needs no token |
| `NPM_TOKEN` | CI secret | Publishing to npmjs (maintainers / GitHub Actions only) |
