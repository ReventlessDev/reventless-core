# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# [3.0.0-alpha.11](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.8...@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.11) (2026-03-27)

* feat!: remove resolverConfig from Behavior module type ([6f54015](https://github.com/ReventlessDev/reventless-core/commit/6f54015e3abc1c5c05472c8f54645723a0f5ed28))

### BREAKING CHANGES

* Behavior.T no longer requires resolverConfig. Remove it
from all Behavior implementations.



# [3.0.0-alpha.10](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.8...@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.10) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-catalog





# [3.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.8...@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.9) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-catalog





# [3.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.7...@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.8) (2026-03-23)

* refactor!: streamline component function naming to unified two-function pattern ([06814fd](https://github.com/ReventlessDev/reventless-core/commit/06814fd8589cf05ce8a9f9654552e7d5cd9c6bf2))

### BREAKING CHANGES

* All component function signatures changed. Behavior.decide
now returns result<array<event>, error> instead of using errorHandler callback.
StateChangeSlice type decisionModel renamed to state. Projection.Mapping.map
renamed to project. StateViewSlice.project takes one argument instead of two.
# [3.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.6...@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.7) (2026-03-22)

* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [3.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.5...@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.6) (2026-03-16)

* feat!: auto-detect plugin version from package.json via V8 stack trace ([e172673](https://github.com/ReventlessDev/reventless-core/commit/e17267390c197fa34052cef8325c579bb781419f))

### BREAKING CHANGES

* Plugin.make no longer accepts ~version.
# [3.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.4...@reventlessdev/online-shop-aggregates-catalog@3.0.0-alpha.5) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# 3.0.0-alpha.4 (2026-03-08)

### Features

* **examples:** add EventMapper, SideEffectHandler, and Task to aggregates online shop ([b8c3237](https://github.com/ReventlessDev/reventless-core/commit/b8c3237f4608f5b85d175ede89d8a335d10afbeb))
* restructure aggregate example into online-shop-aggregates with spec packages ([5aca927](https://github.com/ReventlessDev/reventless-core/commit/5aca927ba1594940219596307c41f00eebd28f9b))
* restructure DCB example into online-shop-dcb with spec packages ([0ee5a10](https://github.com/ReventlessDev/reventless-core/commit/0ee5a10c55248c8e27087f69cdce61a24f98027f))
# [3.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/example-aggregate-catalog@3.0.0-alpha.2...@reventlessdev/example-aggregate-catalog@3.0.0-alpha.3) (2026-03-03)

### Features

* **api:** implement Api component with GraphQL fragment generation and schema stitching ([c882d3a](https://github.com/ReventlessDev/reventless-core/commit/c882d3aae8722cf6cbe9b4fbf9518d9f434ce06a))
# [3.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/example-aggregate-catalog@3.0.0-alpha.1...@reventlessdev/example-aggregate-catalog@3.0.0-alpha.2) (2026-03-02)

### Features

* **examples/aggregate:** connect Catalog and Ordering via extension points ([4631e3f](https://github.com/ReventlessDev/reventless-core/commit/4631e3f92a836d134830ed7c42528a218eeb07f5))
# 3.0.0-alpha.1 (2026-03-01)

* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))
### Features

* **examples:** add DCB-based online shop example with catalog and ordering packages ([45a8159](https://github.com/ReventlessDev/reventless-core/commit/45a8159a6365d8c9ea2665cb58eaf8ee90c3f11d))
* **examples:** restructure examples into examples/ with catalog and ordering bounded contexts ([077720d](https://github.com/ReventlessDev/reventless-core/commit/077720d8881867a2977b5686bc283134de54abef))

### BREAKING CHANGES

* ReventlessSpec namespace renamed to Reventless; the reventless-core
package namespace renamed from Reventless to ReventlessCore.
All usages of ReventlessSpec.* must be updated to Reventless.*;
all usages of Reventless.* (core) in dependent packages must be updated to ReventlessCore.*
