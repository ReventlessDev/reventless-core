# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

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
