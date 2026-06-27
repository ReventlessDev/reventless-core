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

Status (2026-06-23): an **`NPM_TOKEN`** is set as a **repo-level** GitHub Actions secret on
`ReventlessDev/reventless-core` and is **already wired** into `release.yml`, `ci.yml`,
`publish-ppx.yml`, and `build-lambda-layer.yml`. The `.npmrc`, `lerna.json`, and all package
`publishConfig` entries already point at `registry.npmjs.org`. Migration is config-complete.

**CRITICAL token requirement — the 2FA gotcha.** The npm account `reventless` runs 2FA in
`auth-and-writes` mode, so **publishing requires a token that bypasses 2FA**. A plain
read/auth token authenticates (`npm whoami` works) but gets `403 … Two-factor authentication
or granular access token with bypass 2fa enabled is required to publish` on `npm publish`. The
working token is a **Granular Access Token with Read **and Write** permission on the
`@reventlessdev` scope** (granular tokens bypass 2FA for automation). A read-only token, or a
classic "Publish" token (which demands an interactive OTP), will fail in CI.

This bit us on 2026-06-23: the `publish-ppx.yml` per-platform/main publish steps wrapped
`npm publish` in `|| echo "::warning::…"`, so the 403 was swallowed and the jobs went **green
while publishing nothing**. Fixed — the publish steps now fail loudly on any error except a
genuine "version already exists" re-publish.

**Local publish caveat:** the repo `.npmrc` line `_authToken=${NPM_TOKEN}` overrides
`~/.npmrc` when commands run inside the repo tree. For a local `lerna publish`, `export
NPM_TOKEN=<token>` in the shell — setting it via `npm config set` in `~/.npmrc` is ignored
inside the repo.

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

## Post-migration fallout — `.npmrc ${NPM_TOKEN}` breaks pnpm hoisting in deploys (2026-06-27)

The migration switched `.npmrc`'s auth line from `${GITHUB_TOKEN}` →
`${NPM_TOKEN}` and **deferred the `pnpm-lock.yaml` regen**. That combination
silently broke the AWS deploy (`deploy-online-shop-hybrid.yml` →
`deploy-reventless-aws.yml`):

- The deploy's `pnpm install` steps were made **anonymous** (all deps public on
  npmjs), so they ran with `NPM_TOKEN` **undefined**.
- The repo `.npmrc` still hard-references `${NPM_TOKEN}` on its authToken line.
  When that var is undefined, pnpm **fails to parse the whole `.npmrc`** and
  drops `node-linker=hoisted`, falling back to **isolated** linking.
- Under isolated linking, transitive `@pulumi/*` (the SDK + the `pulumi-nodejs`
  dynamic-provider plugin, which lives inside the `@pulumi/pulumi` package) are
  **not hoisted** to the root `node_modules` and are unreachable from the deploy
  program → Pulumi reports `"Pulumi SDK has not been installed"` /
  `"could not read plugin pulumi-resource-pulumi-nodejs: EOF"`.
- Pre-migration this worked because `.npmrc` referenced `${GITHUB_TOKEN}`, which
  is always set in Actions — so hoisting was always honoured.

Symptom is **registry-independent and Pulumi-version-independent**; pinning the
CLI (`pulumi/setup-pulumi`) does nothing. The tell is the repeated
`WARN  Issue while reading ".npmrc". Failed to replace env in config: ${NPM_TOKEN}`
on every pnpm invocation.

**Fix shipped (commit `61df3b445`):** define `NPM_TOKEN` (optional secret, may be
empty — install stays anonymous) on both deploy jobs in
`deploy-reventless-aws.yml` and thread it from the `deploy-online-shop-hybrid.yml`
caller, so `${NPM_TOKEN}` always expands and pnpm honours `node-linker=hoisted`.
Validated: platform + both plugins deploy green. (Catalog also hit an unrelated
AWS state-drift error — deleting a `CategoryAggrCmdTopic` SQS QueuePolicy whose
queue was already gone — which self-healed on a re-dispatch's `pulumi refresh`.)

Two related deploy-chain fixes from the same day:
- `4117a3bc2` — layer-builder retries npmjs registry reads through Cloudflare
  CDN read-after-write propagation lag (`E404` is terminal in
  `npm-registry-fetch`); the layer build is dispatched immediately post-publish.
- `5de41d8a7` — pinned `pulumi/setup-pulumi` to `3.247.0` (hygiene only; NOT a
  fix for the above — kept to stop silent version float).

**Durable cleanup (TODO — the proper fix):** regenerate `pnpm-lock.yaml` against
npmjs (the regen this plan deferred "until ppx + UI packages are published").
Until then, hoisting stays brittle and the `NPM_TOKEN`-defined workaround is
load-bearing. Also consider making the `.npmrc` authToken tolerant of an
undefined token so a missing `NPM_TOKEN` can't silently disable hoisting again.

## Related (this repo)

- `docs/plans/docs-site-open-source-publication.md` — public docs cut.
- `docs/plans/prebuilt-binaries-out-of-repo.md` — PPX/binary packaging.
