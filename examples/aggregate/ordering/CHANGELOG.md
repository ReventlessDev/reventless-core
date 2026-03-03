# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# [3.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/example-aggregate-ordering@3.0.0-alpha.3...@reventlessdev/example-aggregate-ordering@3.0.0-alpha.4) (2026-03-03)

### Features

* **examples:** add example-aggregate package with self-assembling aggregate plugins ([6a080f1](https://github.com/ReventlessDev/reventless-core/commit/6a080f1be08420dc61f1bffcbfe7f80e678f2963))


# [3.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/example-aggregate-ordering@3.0.0-alpha.2...@reventlessdev/example-aggregate-ordering@3.0.0-alpha.3) (2026-03-03)

### Features

* **api:** implement Api component with GraphQL fragment generation and schema stitching ([c882d3a](https://github.com/ReventlessDev/reventless-core/commit/c882d3aae8722cf6cbe9b4fbf9518d9f434ce06a))


# [3.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/example-aggregate-ordering@3.0.0-alpha.1...@reventlessdev/example-aggregate-ordering@3.0.0-alpha.2) (2026-03-02)

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

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
