# Plan: npm publishing proves where packages came from, and the Intel-Mac PPX gets a settled home

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/npmjs-publish-migration.md](../done/npmjs-publish-migration.md) and [../done/prebuilt-binaries-out-of-repo.md](../done/prebuilt-binaries-out-of-repo.md) when they closed. Optional hardening: publishing works today with a token, and Intel Macs build the PPX locally without friction.<br/>
**Relates to:** [../done/ppx-republish-single-commit.md](../done/ppx-republish-single-commit.md) — why this repo's own builds no longer depend on the published PPX pin.

---

## In plain words

`@reventlessdev/*` packages publish to public npmjs with a long-lived access
token (`NPM_TOKEN` / `NODE_AUTH_TOKEN`), and the native PPX binary ships as
per-platform packages for Linux x64 and Apple Silicon. Three loose ends remain,
none urgent.

## 1. Provenance, and maybe tokenless publishing

- **Provenance** (`npm publish --provenance`): npm then shows, per version, the
  repository commit and workflow run that built it — a supply-chain
  attestation. It needs `permissions: id-token: write` on the publishing job.
  No workflow passes `--provenance` today (checked 2026-10-07).
- **Trusted Publishing (OIDC)**: npm accepts a short-lived token minted by
  GitHub Actions instead of the stored secret, so there is no long-lived
  credential to leak. Unverified whether the per-package `pnpm publish` loop in
  `release-packages.yml` (and the PPX publish in `publish-ppx.yml`) supports the
  token exchange — test it on a throwaway package first. It also needs a
  Trusted-Publisher entry per package on npmjs.

Do provenance first: it is one flag plus one permission per publishing job.
Note the 2FA lesson from the migration: a publish that silently does nothing
is the failure to watch for, so check the registry (with `curl`, not `npm
view`) after the first run.

## 2. An install from published packages only

CI installs with `--frozen-lockfile` on a fresh checkout, but inside the
workspace every `@reventlessdev/*` dependency resolves to the local source. No
check installs the **published** packages the way an outside user would — for
example a scaffolded app (`create-app` in reventless-tools) or a copy of one
example pinned to published versions — and runs build and test. That is the
only thing that would catch a package that builds here but ships without a
file it needs.

## 3. darwin-x64 (Intel Mac) PPX: settle it either way

Today darwin-x64 is out of the CI matrix and published by hand from an Intel
Mac (`node scripts/publish-ppx-local.mjs darwin-x64`, documented in
`.github/workflows/publish-ppx.yml`). It is deliberately absent from
`optionalDependencies` in `packages/reventless-ppx/package.json`, so an Intel
consumer falls back to a local build. Pick one:

- **Keep it**: build it in CI under Rosetta (`arch -x86_64` on `macos-14`), then
  add it to `optionalDependencies` (and to `pin-ppx.mjs`) so Intel users get it
  from `pnpm install`.
- **Sunset it**: stop the manual publish, deprecate the package on npm, and say
  in the PPX README that Intel Macs build locally with `pnpm build:ppx`.

The manual path is the one to avoid long-term: it depends on one machine, and a
missed run leaves the Intel binary a version behind.

## Done when

Releases carry provenance (and OIDC is adopted or ruled out with a reason), an
outside-style install of published packages runs somewhere on a schedule or
per release, and darwin-x64 is either in `optionalDependencies` or deprecated.
