# Plan: Publish Reventless Conventional Changelog Preset as Package

## Overview

Move `packages/conventional-changelog-reventless/` to `reventless/reventless-conventional-changelog/`, rename it to `@reventlessdev/reventless-conventional-changelog`, and publish it to the GitHub Package Registry like all other `@reventlessdev` packages. Update `reventless-core` to consume the published package instead of the local `file:` reference.

---

## Step 1: Move and Rename the Package

- [ ] Move `packages/conventional-changelog-reventless/` → `reventless/reventless-conventional-changelog/`
- [ ] Update `reventless/reventless-conventional-changelog/package.json`:
  - Change `"name"` from `"conventional-changelog-reventless"` to `"@reventlessdev/reventless-conventional-changelog"`
  - Remove `"private": true`
  - Add `"publishConfig": { "registry": "https://npm.pkg.github.com" }`
  - Add `"license": "SEE LICENSE IN LICENSE.md"` (consistent with other packages)
- [ ] Update `reventless/reventless-conventional-changelog/CHANGELOG.md`: fix comparison URLs from `conventional-changelog-reventless@` to `@reventlessdev/reventless-conventional-changelog@`

---

## Step 2: Update Root `package.json` in reventless-core

- [ ] Update the `devDependencies` entry:
  ```json
  "@reventlessdev/reventless-conventional-changelog": "file:./reventless/reventless-conventional-changelog"
  ```
  (was `"conventional-changelog-reventless": "file:./packages/conventional-changelog-reventless"`)
- [ ] Run `npm install` to update `package-lock.json`

---

## Step 3: Update `lerna.json` in reventless-core

The `changelogPreset` field uses the package name to load the preset. Rename from the short alias `"reventless"` (which loads `conventional-changelog-reventless`) to the full scoped package name, which `conventional-changelog-preset-loader` resolves directly:

- [ ] In `lerna.json`, update both occurrences of `"changelogPreset"`:
  ```json
  "changelogPreset": "@reventlessdev/reventless-conventional-changelog"
  ```
  (was `"changelogPreset": "reventless"` in both `command.version` and `command.publish`)

---

## Step 4: Update `.github/workflows/release.yml` in reventless-core

The release workflow already publishes all non-private packages in `reventless/*` when they have changes. No new publish step is needed — removing `"private": true` and adding `publishConfig` in Step 1 is sufficient for Lerna to include it.

One adjustment is needed: the `lerna version` commands pass `--ignore-changes doc --ignore-changes reventless-layer-builder` to exclude those private packages from triggering version bumps. The changelog preset package is in `reventless/` and should be versioned normally, so no ignore entry is needed. However, the `Create GitHub releases` step skips packages named `doc` or `reventless-layer-builder` — `reventless-conventional-changelog` is not in that list, so it will get a GitHub release automatically.

- [ ] Verify the `Create GitHub releases` step skip list does not need updating (it should not)
- [ ] Confirm `lerna changed` picks up the moved package after `npm install` regenerates the lock file

## Notes

- The package currently has no `LICENSE.md`. Adding one is optional but consistent with other `@reventlessdev` packages.
- After the move, delete the now-empty `packages/` directory if `conventional-changelog-reventless` was its only remaining occupant — check first with `ls packages/`.
