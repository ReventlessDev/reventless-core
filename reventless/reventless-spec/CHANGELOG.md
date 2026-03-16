# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# [3.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.8...@reventlessdev/reventless-spec@3.0.0-alpha.9) (2026-03-16)

* feat!: auto-detect plugin version from package.json via V8 stack trace ([e172673](https://github.com/ReventlessDev/reventless-core/commit/e17267390c197fa34052cef8325c579bb781419f))
### Features

* read version from package.json, make cloner opt-in, log platform version ([d8216a1](https://github.com/ReventlessDev/reventless-core/commit/d8216a1d569064ca14eff6e0c3be86923e5b84ad))

### BREAKING CHANGES

* Plugin.make no longer accepts ~version.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>



# [3.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.7...@reventlessdev/reventless-spec@3.0.0-alpha.8) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))


# [3.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.5...@reventlessdev/reventless-spec@3.0.0-alpha.7) (2026-03-08)

### Bug Fixes

* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))
* replace explicit queryMode with automatic schema-driven DCB query construction ([8df4350](https://github.com/ReventlessDev/reventless-core/commit/8df4350c37f1f15678f4796f229647eaeb3e8222))


# [3.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.5...@reventlessdev/reventless-spec@3.0.0-alpha.6) (2026-03-08)

### Bug Fixes

* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))


# [3.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.4...@reventlessdev/reventless-spec@3.0.0-alpha.5) (2026-03-03)

### Features

* **api:** implement Api component with GraphQL fragment generation and schema stitching ([c882d3a](https://github.com/ReventlessDev/reventless-core/commit/c882d3aae8722cf6cbe9b4fbf9518d9f434ce06a))


# [3.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.3...@reventlessdev/reventless-spec@3.0.0-alpha.4) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# [3.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.2...@reventlessdev/reventless-spec@3.0.0-alpha.3) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# [3.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.1...@reventlessdev/reventless-spec@3.0.0-alpha.2) (2026-03-01)

* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))
### Features

* **rescript-effect:** Effect library bindings + stream-based framework handlers ([#30](https://github.com/ReventlessDev/reventless-core/issues/30)) ([f2ca5cf](https://github.com/ReventlessDev/reventless-core/commit/f2ca5cf3d56d66a9f4ab56b543d7bf82e48448dd))

### BREAKING CHANGES

* ReventlessSpec namespace renamed to Reventless; the reventless-core
package namespace renamed from Reventless to ReventlessCore.
All usages of ReventlessSpec.* must be updated to Reventless.*;
all usages of Reventless.* (core) in dependent packages must be updated to ReventlessCore.*

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>



# [3.0.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.0...@reventlessdev/reventless-spec@3.0.0-alpha.1) (2026-02-14)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# [3.0.0-alpha.0](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@2.3.1-alpha.2...@reventlessdev/reventless-spec@3.0.0-alpha.0) (2026-02-13)

* refactor!: remove AWS dependencies from reventless core package ([bc2c4af](https://github.com/ReventlessDev/reventless-core/commit/bc2c4aff85af4f83b9d131584845260b060db647))

### BREAKING CHANGES

* Builder functions now require explicit resourceNaming and runtimeOps parameters

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>



## [2.3.1-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@2.3.1-alpha.1...@reventlessdev/reventless-spec@2.3.1-alpha.2) (2026-02-12)

**Note:** Version bump only for package @reventlessdev/reventless-spec





## [2.3.1-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@2.3.1-alpha.0...@reventlessdev/reventless-spec@2.3.1-alpha.1) (2026-02-12)

**Note:** Version bump only for package @reventlessdev/reventless-spec





## 2.3.1-alpha.0 (2026-02-12)


### Bug Fixes

* **publish:** add publishConfig to packages for GitHub Package Registry ([987a00a](https://github.com/ReventlessDev/reventless-core/commit/987a00af049fed112aa91fd53d8fad719cd80c94))
