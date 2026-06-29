# Plan (Backlog): Republish reventless-ppx so externalSystem injects on inline specs

**Status:** Backlog (not started)

**Trigger commit:** `19bbb2fa7` (fix(test): set externalSystem on translation slice
fixtures for published PPX) — the stopgap this plan retires.

**Related:** `3f8ad39b7` (feat: external-system boxes for translation slices),
`d399e884c` (feat(ppx): inline-spec walk + Spec module types require authorization).

---

## Problem

The `InboundTranslationSlice.Spec` and `OutboundTranslationSlice.Spec` module types now
require `let externalSystem: option<string>` (added in `3f8ad39b7`). The field is meant
to be auto-injected by the PPX, defaulting to `None`:

- **File-level `@@reventless.spec`** files (the example/app translation slices) get the
  injection from the *published* PPX binary, so they compile in CI.
- **Structurally-detected inline spec modules** (hand-written `module XSpec = { ... }`
  blocks inside test fixtures, with no `@@reventless.spec` attribute) are injected by the
  PPX's *inline-spec walk*. The **local** PPX (osx fallback, freshly built from source)
  injects `externalSystem` there — which is why the committed `.res.mjs` already carried
  `externalSystem: undefined`. But **CI's published PPX binary predates that injection**,
  so the Release build failed to compile two fixtures:
  - `reventless/reventless-local/tests/components/inboundtranslationslice/InboundTranslationSliceFixtures.res`
  - `reventless/reventless-local/tests/components/outboundtranslationslice/OutboundTranslationSliceFixtures.res`

The same divergence exists for `commandAuthorization` historically, but that one *was*
republished, so the inline walk injects it and no error surfaced.

### Why this keeps biting

This is the documented PPX-distribution constraint: **PPX source changes that add a
required-field auto-injection cannot pass CI until the PPX is republished** — local dev
uses the gitignored `ppx-osx.exe` built from current source, CI uses the published
binary (see memory `feedback_ppx_linux_rebuild`, `reference_reventless_ppx_publishing_pitfalls`).

## Current stopgap (already shipped)

Commit `19bbb2fa7` added `let externalSystem = None` explicitly to the two fixture spec
modules. It is idempotent with the PPX injection (injected only "if absent"), so it stays
correct after republish — just redundant.

**Until republish, any *new* hand-written inline translation spec (test fixture or inline
builder-body module) must set `let externalSystem = None` manually**, or CI breaks again.

## Root cause (verified 2026-06-29) — NOT an implementation gap

The injection **is implemented** in source at version `1.0.0-alpha.47`
([AuthorizationInjection.ml](../../../packages/reventless-ppx/src/ppx/AuthorizationInjection.ml)
`walk_inline_specs` → `inject_external_system_into_inner_module`, both inbound and outbound,
from `3f8ad39b7`). The problem is **the published binary**, and the precise mechanism is a
**lerna-only-bumps-the-main-package** desync (verified by direct registry curl — `npm view`
lies here because `.npmrc` sets `prefer-offline=true`):

- Main `@reventlessdev/reventless-ppx`: **alpha.47** on npmjs ✓ (`latest = alpha.47`).
- Per-platform `-linux-x64` / `-darwin-arm64`: **stuck at alpha.46**. Those alpha.46 binaries
  were compiled *before* `3f8ad39b7`, so they lack the injection.

Why the binaries are stuck: lerna's version bump touched only the **main**
`packages/reventless-ppx/package.json` (→ alpha.47); the per-platform scaffolds
`packages/reventless-ppx/npm/{linux-x64,darwin-arm64,darwin-x64}/package.json` stayed at
**alpha.46**. publish-ppx's publish step does `cd npm/<target> && npm publish`, which
publishes the version in the *scaffold* (alpha.46) → "already exists" → the step's
`|| ::warning` swallows it → job reports **success** while publishing nothing new. Both the
2026-06-23 run and a 2026-06-29 re-dispatch no-op'd this way.

CI then fails on two compounding facts: (a) the committed `pnpm-lock.yaml` **pins** the
per-platform packages at `@1.0.0-alpha.46`, and `--frozen-lockfile` installs exactly that;
(b) there is no alpha.47 per-platform package to upgrade to anyway. The alpha.46 binary
lacks the injection → the inline test fixtures fail to compile.

Notes:
- **`darwin-x64` is intentionally left at alpha.46 for now.** It was never published to
  npmjs at all (so its `^alpha.45` optionalDep already resolves to nothing and is silently
  dropped). CI runs on `linux-x64`; Intel-Mac maintainers fall back to the launcher's local
  build (`pnpm run setup` / `pnpm build:ppx`), which already injects `externalSystem`.
- **The stopgap (`19bbb2fa7`) already unblocks CI without any republish** — the fixtures now
  carry `let externalSystem = None` explicitly, so they compile under the alpha.46 binary.
  This plan is the *proper* fix that lets the stopgap be removed; it is not urgent.

## Goal

Publish the **per-platform** `linux-x64` + `darwin-arm64` binaries at alpha.47 (lockstep
with the already-published main package) and repoint the lockfile, so CI resolves a binary
that injects `externalSystem` on inline specs. Then the stopgap lines can be removed.

## Steps (the publish + lockfile steps are push-gated — require a push to `alpha`)

1. **Lockstep-bump the per-platform scaffolds** `packages/reventless-ppx/npm/{linux-x64,
   darwin-arm64}/package.json` → `1.0.0-alpha.47` (leave `darwin-x64`). *(Staged uncommitted
   on 2026-06-29.)*
2. **Commit + push** the scaffold bump to `alpha` (publish-ppx builds from the remote
   branch, so the bump must be pushed).
3. **Dispatch** `publish-ppx.yml` (`workflow_dispatch`, `publish: true`) → now `cd npm/<t>`
   publishes alpha.47 for `linux-x64` + `darwin-arm64`. Verify with a DIRECT curl of each
   per-platform packument (not `npm view` — stale cache), and bust the local pnpm metadata
   cache (`~/Library/Caches/pnpm/metadata*/.../reventless-ppx*.json`) before re-resolving.
4. **Bump optionalDeps** in the main package.json `^1.0.0-alpha.45` → `^1.0.0-alpha.47` for
   `linux-x64` + `darwin-arm64` (a range that *requires* alpha.47 — `pnpm update` will NOT
   cross a prerelease range otherwise), then `pnpm install --lockfile-only
   --config.prefer-offline=false`. Confirm the lock now pins alpha.47. Commit + push.
5. **Add a regression test** in `packages/reventless-ppx/test/run.sh`: an inline-spec
   fixture (no `@@reventless.spec`) asserting `externalSystem: undefined` is emitted, so a
   future source-side regression is caught by the PPX test. (Note: the PPX test builds from
   *current source*, so it guards source regressions, not the publish-lag itself.)
6. **Prevent recurrence**: the per-platform scaffolds must be bumped in lockstep with the
   main package on every PPX release. Options — drive the scaffold versions from the main
   `package.json` in `publish-ppx.yml` (single source of truth), add a lockstep-assertion
   step that fails the publish if `npm/*/package.json` ≠ main, or bring the scaffolds into
   lerna's version scope. Pick one and document it.
7. **Cleanup**: remove the redundant `let externalSystem = None` stopgap lines from the two
   fixtures in `19bbb2fa7` once CI is green on the published binary.

## Acceptance

- Direct curl of `…/@reventlessdev%2Freventless-ppx-linux-x64` and `-darwin-arm64` shows
  `latest = 1.0.0-alpha.47` (`darwin-x64` deferred).
- `pnpm-lock.yaml` pins the per-platform packages at alpha.47.
- A hand-written inline translation spec with no `externalSystem` compiles in CI under the
  published PPX, with the stopgap lines removed.
- `pnpm run build` is green end-to-end without the manual stopgap lines.
