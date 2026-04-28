# Plan: Adopt `@reventlessdev/reventless-playground` (rename of `@reventlessdev/dev-app`)

Consumes the rename owned by [reventless-ui/docs/plans/rename-dev-app-to-reventless-playground.md](../../../reventless-ui/docs/plans/rename-dev-app-to-reventless-playground.md). Run **after** the new package is published on npm and the old name is deprecated.

## Goal

Update this repo's example consumer and the local-dev guide to use the renamed package and bin. No framework changes.

| | Before | After |
|---|---|---|
| Dependency | `@reventlessdev/dev-app` | `@reventlessdev/reventless-playground` |
| Bin invoked from scripts | `dev-app` | `reventless-playground` |

## Prerequisite

`@reventlessdev/reventless-playground@>=0.3.0-alpha.0` must be published to the GitHub npm registry. Confirm with:

```bash
gh api /orgs/ReventlessDev/packages/npm/reventless-playground/versions
```

If the package is not yet published, do not start this plan — the install will fail.

## File-by-file edits

### 1. Example consumer

[examples/online-shop-hybrid/platform-in-memory/package.json](../../examples/online-shop-hybrid/platform-in-memory/package.json):

- Line 12 — `dev:ui` script:
  ```diff
  - "dev:ui": "[ -d reventless-ui ] && pnpm --filter ./reventless-ui run dev:ui || dev-app",
  + "dev:ui": "[ -d reventless-ui ] && pnpm --filter ./reventless-ui run dev:ui || reventless-playground",
  ```
- Line 16 — `optionalDependencies`:
  ```diff
  - "@reventlessdev/dev-app": ">=0.2.0-alpha"
  + "@reventlessdev/reventless-playground": ">=0.3.0-alpha"
  ```

Bump the package version (`1.0.0-alpha.27` or whatever is next in the alpha train) since the consumer-facing dependency changed.

### 2. Local dev guide

[docs/guides/local-dev.md](../guides/local-dev.md) — update every reference to the old name:

- Line 43 — table row in "How the UI dev server is resolved":
  ```diff
  - | 2 | Symlink dangling / absent | `dev-app` binary from installed `@reventless/dev-app` | No — published snapshot |
  + | 2 | Symlink dangling / absent | `reventless-playground` binary from installed `@reventlessdev/reventless-playground` | No — published snapshot |
  ```
  Note: the old guide also had the `@reventless/` (single-word) typo — fix to `@reventlessdev/` while editing.
- Line 45:
  ```diff
  - `@reventless/dev-app` is a `devDependency` of this package. It is always available without checking out the UI source repo.
  + `@reventlessdev/reventless-playground` is a `devDependency` of this package. It is always available without checking out the UI source repo.
  ```
- Line 90 — "Writing your own local dev entry-point":
  ```diff
  - Add run scripts to the plugin's `package.json`, add `@reventless/dev-app` as a `devDependency`, and create a `reventless-ui` symlink the same way:
  + Add run scripts to the plugin's `package.json`, add `@reventlessdev/reventless-playground` as a `devDependency`, and create a `reventless-ui` symlink the same way:
  ```
- Line 98 — example `devDependencies` block:
  ```diff
  - "@reventless/dev-app": "*"
  + "@reventlessdev/reventless-playground": "*"
  ```
- Line 102 — example `dev:ui` script:
  ```diff
  - "dev:ui": "[ -d reventless-ui ] && pnpm --filter ./reventless-ui run dev:ui || dev-app",
  + "dev:ui": "[ -d reventless-ui ] && pnpm --filter ./reventless-ui run dev:ui || reventless-playground",
  ```

### 3. Other in-repo plans/docs that mention the old name

These are decision documents (no code refs into the package). Update prose only:

- [docs/plans/entity-reference-dropdowns.md](entity-reference-dropdowns.md)
- [docs/plans/online-shop-hybrid-autoui-local-e2e.md](online-shop-hybrid-autoui-local-e2e.md)
- [docs/plans/pnpm-migration.md](pnpm-migration.md)
- [docs/plans/done/online-shop-hybrid-autoui-devapp.md](done/online-shop-hybrid-autoui-devapp.md) — done plans are historical; leave as-is.
- [docs/plans/done/event-graph-phase7.md](done/event-graph-phase7.md) — done; leave.
- [docs/plans/done/local-ui-dev-setup.md](done/local-ui-dev-setup.md) — done; leave.

For active plans, the rule is: if a paragraph still drives upcoming work, update the name; if it's just describing past state, leave it.

The CHANGELOG entry in [examples/online-shop-hybrid/platform-in-memory/CHANGELOG.md](../../examples/online-shop-hybrid/platform-in-memory/CHANGELOG.md) is git history — leave verbatim.

### 4. Lockfile

`pnpm install` after the package.json edit. The lockfile will drop `@reventlessdev/dev-app` and add `@reventlessdev/reventless-playground` under the same resolution rules.

## Validation

From `examples/online-shop-hybrid/platform-in-memory/`:

1. `pnpm install` resolves the new package from the GitHub npm registry.
2. With **no** `reventless-ui` symlink present:
   ```bash
   pnpm run build
   pnpm run dev:full
   ```
   confirm the UI process logs `vite preview` from `node_modules/@reventlessdev/reventless-playground/dist/` and serves at `:5173`.
3. With the `reventless-ui` symlink present, `dev:full` should still take the **first** branch of `dev:ui` (the symlinked source repo), unaffected by the rename.
4. The deprecation message on the old package should appear when running `pnpm install` if any transitive dependency still pins the old name. If it appears, search for the leftover ref and remove it.

## Out of scope

- Any change to the playground's behaviour, bundler, or relay wiring. This plan only swaps a package name and a bin name.
- Changes to `dev:ui` / `dev:full` script *names* — only the fallback bin inside `dev:ui` changes.
- Changes to the symlinked-source-repo branch of `dev:ui`. The symlink path and the filtered package name (`./reventless-ui`) are unchanged.
