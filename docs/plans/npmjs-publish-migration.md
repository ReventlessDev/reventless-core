# Plan: migrate `@reventlessdev/*` publishing to public npmjs at OSS launch

## Goal & trigger

At the open-source launch, this repo does **two** things together:

1. **Goes public on GitHub** (`ReventlessDev/reventless-core`).
2. **Moves `@reventlessdev/*` package publishing** from private GitHub Packages
   (`npm.pkg.github.com`) → **public npmjs** (`registry.npmjs.org`).

These are the single trigger event that (a) dissolves the GitHub Packages storage-quota
constraint, (b) makes external `npm install @reventlessdev/*` work, and (c) is the moment to
flip from a linking/private-registry baseline to a **published-only, public baseline**.

**Until launch, everything stays private** (private repo + private GitHub Packages). This plan
is the launch-day execution, not something to do early.

## npmjs scopes — already claimed (2026-06-23)

- npm org **`reventlessdev`** created under npm user **`reventless`** → owns the
  `@reventlessdev` scope. (`reventless` also reserves the bare `@reventless` scope.)
- Org is on the **Free** tier — unlimited **public** scoped packages; private scoped packages
  would need a paid plan, but everything here publishes **public**.
- A deprecated `@reventlessdev/placeholder@0.0.0` is parked as a visible claim.

## Gates (must hold before going public at all)

- Pre-public **git-history rewrite** window completed (going public forfeits it).
- **Patent disclosure** gate satisfied.
- Do **not** go public *merely* to dodge the GitHub Packages storage limit — the migration
  rides on the real launch.
- Docs-site public cut coordinated — see `docs/plans/docs-site-open-source-publication.md`
  (Phase 8 domain cutover).

## Auth — DECISION: token-only (`NPM_TOKEN`) baseline

Token publishing is the launch baseline; Trusted Publishing (OIDC) is **optional post-launch
hardening**, deferred because:

- `lerna publish` (this repo's publish path) may not support npm-CLI OIDC token exchange —
  **unverified**; would need a throwaway-package test before relying on it.
- Token-only avoids per-package Trusted-Publisher setup across the full publishable set.

Status: an **`NPM_TOKEN`** (npm automation/granular token, scoped to `@reventlessdev`) has been
minted and added as a **`ReventlessDev` GitHub org Actions secret** (2026-06-23), available to
this repo. **Not yet wired into workflows.**

Optional later: emit provenance with `npm publish --provenance` (needs `id-token: write`) for
the supply-chain attestation, without full OIDC.

## Touchpoints (concrete edits at launch)

### `.npmrc`
Drop the GitHub Packages routing + auth lines:
```
@reventlessdev:registry=https://npm.pkg.github.com     # remove
//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}        # remove
```
`registry=https://registry.npmjs.org` is already the default. Add npmjs auth for CI:
```
//registry.npmjs.org/:_authToken=${NPM_TOKEN}
```
`access=restricted` is fine to leave (we force `--access public` at publish, below), or set
`access=public`.

### `lerna.json`
```jsonc
"command": {
  "publish": {
    "registry": "https://npm.pkg.github.com",   // → "https://registry.npmjs.org"
    "access": "public",                          // ADD — scoped pkgs default to restricted
    ...
  }
}
```

### `package.json` publishConfig — root **and every package that sets it**
Root `reventless-monorepo` is `private:true` (not published), but its
`publishConfig.registry: "https://npm.pkg.github.com"` is inherited; change → npmjs or remove.
**Every package** carrying `publishConfig.registry: https://npm.pkg.github.com` must change —
this currently spans `packages/*`, `rescript/*`, `reventless/*`, **and the `examples/**`
tree** (online-shop-hybrid / -aggregates / -dcb / -platform). Sweep:
```
grep -rl 'npm.pkg.github.com' --include=package.json . | grep -v node_modules
```

### Workflows — swap `GITHUB_TOKEN` → `NPM_TOKEN`
For the install/publish steps in `release.yml`, `ci.yml`, `publish-ppx.yml`, and the
`deploy-*.yml` jobs that install `@reventlessdev/*`. (Leave `GITHUB_TOKEN` where it's used for
GitHub API / release creation, e.g. lerna `createRelease: github` — that still needs it.)

## Package size — PPX per-platform split

Split the fat `reventless-ppx` into per-platform packages so installs are fast and stay under
npm tarball limits. No longer a storage *gate* on public npm, but required UX-wise for a
public package and for `publish-ppx.yml`. See `docs/plans/prebuilt-binaries-out-of-repo.md`.

## Examples as a public contract?

The `examples/**` packages currently publish privately. Decide at launch whether the
online-shop examples become a **public npm contract** (republished public) or stay
unpublished/private. Republishing them public is what makes a clean external
`clone → install → build` of the examples work.

## Verification

- Fresh clone (no `GITHUB_TOKEN`, public sources): `pnpm install` → `pnpm build` → `pnpm test`
  green from public npm.
- A throwaway external-style environment (no org membership) can `npm install` the public
  `@reventlessdev/*` packages.
- `release.yml` / `publish-ppx.yml` green on a branch before the public flip.

## Related (this repo)

- `docs/plans/docs-site-open-source-publication.md` — public docs cut.
- `docs/plans/prebuilt-binaries-out-of-repo.md` — PPX/binary packaging.
