[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-conventional-changelog.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-conventional-changelog)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-conventional-changelog

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

A **custom [conventional-changelog](https://github.com/conventional-changelog/conventional-changelog)
preset** used to generate changelogs across the
[Reventless](https://docs.reventless.dev) monorepo — a spec-driven, event-sourced
CQRS framework written in [ReScript](https://rescript-lang.org). It extends the
Angular preset with monorepo-friendly tweaks so per-package changelogs stay
compact and informative.

## What it provides

A single preset factory (`index.js`) that wraps
`conventional-changelog-angular` and:

- **Strips `Co-Authored-By:` trailers** from commit bodies, footers, and notes so
  they don't leak into changelog entries.
- **Reduces blank lines** via a tightened main template.
- **Adds a "Dependency Updates" section** for dependency-only version bumps:
  when a package has no conventional commits, it diffs the package's
  `dependencies` / `devDependencies` / `peerDependencies` against the last
  committed `package.json` and lists what actually changed, instead of the
  generic "Version bump only" line.

## Where it fits

This is build/release tooling, not part of the framework runtime. It plugs into a
conventional-changelog / Lerna release pipeline as the preset, and resolves
per-package directories from `lerna.json` workspace globs to compute dependency
diffs.

## Install

```bash
pnpm add -D @reventlessdev/reventless-conventional-changelog
```

Point your changelog tooling at it as the preset — for example with Lerna:

```json
{
  "changelogPreset": "@reventlessdev/reventless-conventional-changelog"
}
```

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
