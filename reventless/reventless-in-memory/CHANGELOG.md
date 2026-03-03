# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.4...@reventlessdev/reventless-in-memory@1.0.0-alpha.5) (2026-03-03)

### Bug Fixes

* **deps:** deduplicate graphql package to resolve schema conflict ([c33b030](https://github.com/ReventlessDev/reventless-core/commit/c33b030c14993e27700c5f0ec44a8a6ebe582468))
* **graphql:** register DCB mutation resolvers and fix schema timing ([3e7da8d](https://github.com/ReventlessDev/reventless-core/commit/3e7da8df7efb20a0ff3dc7c82e10a807cb516182))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* **graphql:** add GRAPHQL_DEBUG mode, schema inspector, and debugging guide ([61fcbee](https://github.com/ReventlessDev/reventless-core/commit/61fcbee6ee68337e95b5934a14279420e8ab8eca))


# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.3...@reventlessdev/reventless-in-memory@1.0.0-alpha.4) (2026-03-03)

### Features

* **api:** implement Api component with GraphQL fragment generation and schema stitching ([c882d3a](https://github.com/ReventlessDev/reventless-core/commit/c882d3aae8722cf6cbe9b4fbf9518d9f434ce06a))
* **platform:** expose Plugin, Core, makeScheduler, makePlatform via Platform.T ([0df4bf3](https://github.com/ReventlessDev/reventless-core/commit/0df4bf333ea4f9c0e51e96df1ad0da4ab471ffe8))


# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.2...@reventlessdev/reventless-in-memory@1.0.0-alpha.3) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 1.0.0-alpha.2 (2026-03-01)

### Bug Fixes

* **in-memory:** replace deprecated String.sliceToEnd with String.slice ([a9dfd00](https://github.com/ReventlessDev/reventless-core/commit/a9dfd00df1bff66adcd56a4b804b47d634b823c1))
* **reventless-in-memory:** expand AsyncTest include to avoid external [@send](https://github.com/send) binding errors ([a9f7b55](https://github.com/ReventlessDev/reventless-core/commit/a9f7b553226f23c7700c54ae00fc92ed315b1098))
* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))
* feat(reventless-core)!: rename package from @reventlessdev/reventless to @reventlessdev/reventless-core ([5e93146](https://github.com/ReventlessDev/reventless-core/commit/5e9314692b5b5d60beee187564ba94bc9fd46c05))
### Features

* **in-memory:** implement P0 GraphQL server for mutations and queries ([2627cdc](https://github.com/ReventlessDev/reventless-core/commit/2627cdc147b2deeb160e9642750bf26da8f95108))
* **in-memory:** implement P1/P2 gaps — QueryEngine, Counter, Scheduler ([faa2d52](https://github.com/ReventlessDev/reventless-core/commit/faa2d52e205f81d3c0d8a203a5b69dcaa19cf218))
* **in-memory:** implement P3 gap — HeartbeatRunner_InMemory ([9f188b5](https://github.com/ReventlessDev/reventless-core/commit/9f188b53d23eae1a768f96291ad75435a828b309))
* **rescript-effect:** Effect library bindings + stream-based framework handlers ([#30](https://github.com/ReventlessDev/reventless-core/issues/30)) ([f2ca5cf](https://github.com/ReventlessDev/reventless-core/commit/f2ca5cf3d56d66a9f4ab56b543d7bf82e48448dd))

### BREAKING CHANGES

* ReventlessSpec namespace renamed to Reventless; the reventless-core
package namespace renamed from Reventless to ReventlessCore.
All usages of ReventlessSpec.* must be updated to Reventless.*;
all usages of Reventless.* (core) in dependent packages must be updated to ReventlessCore.*

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
* package renamed for consistency with sibling packages
and the repository name. ReScript namespace "Reventless" is unchanged —
no source code updates required.

- git mv reventless/reventless → reventless/reventless-core
- package.json and rescript.json name updated to @reventlessdev/reventless-core
- reventless-aws and reventless-in-memory dependency references updated
- Root package.json and rescript.json renamed to "reventless-monorepo" to
  avoid name collision that caused ReScript to skip building the sub-package
- Updated recompiled .res.mjs output files with new relative import paths

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
