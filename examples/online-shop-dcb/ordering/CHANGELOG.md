# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.5 (2026-03-08)

### Features

* **examples:** add AutomationSlice, InboundTranslationSlice, and OutboundTranslationSlice to DCB online shop ([6e2da0a](https://github.com/ReventlessDev/reventless-core/commit/6e2da0a2629085750bdd707feb961e4e65c2c70c))
* restructure DCB example into online-shop-dcb with spec packages ([0ee5a10](https://github.com/ReventlessDev/reventless-core/commit/0ee5a10c55248c8e27087f69cdce61a24f98027f))


# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/example-dcb-ordering@1.0.0-alpha.3...@reventlessdev/example-dcb-ordering@1.0.0-alpha.4) (2026-03-03)

### Features

* **api:** implement Api component with GraphQL fragment generation and schema stitching ([c882d3a](https://github.com/ReventlessDev/reventless-core/commit/c882d3aae8722cf6cbe9b4fbf9518d9f434ce06a))


# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/example-dcb-ordering@1.0.0-alpha.2...@reventlessdev/example-dcb-ordering@1.0.0-alpha.3) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/example-dcb-ordering





# [1.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/example-dcb-ordering@1.0.0-alpha.1...@reventlessdev/example-dcb-ordering@1.0.0-alpha.2) (2026-03-02)

### Features

* **examples/dcb:** connect Catalog and Ordering via extension points ([bc95640](https://github.com/ReventlessDev/reventless-core/commit/bc95640cfe8c52a4e95e8c3216a53a29c4f08493))

### BREAKING CHANGES

* **examples/dcb:** OrderCancelled now carries `productIds: array<string>`
so the OrdersExtensionPoint can decompose cancellations into per-product
ItemOrderCancelled events.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>



# 1.0.0-alpha.1 (2026-03-01)

* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))
### Features

* **examples:** add DCB-based online shop example with catalog and ordering packages ([45a8159](https://github.com/ReventlessDev/reventless-core/commit/45a8159a6365d8c9ea2665cb58eaf8ee90c3f11d))
* **rescript-effect:** Effect library bindings + stream-based framework handlers ([#30](https://github.com/ReventlessDev/reventless-core/issues/30)) ([f2ca5cf](https://github.com/ReventlessDev/reventless-core/commit/f2ca5cf3d56d66a9f4ab56b543d7bf82e48448dd))

### BREAKING CHANGES

* ReventlessSpec namespace renamed to Reventless; the reventless-core
package namespace renamed from Reventless to ReventlessCore.
All usages of ReventlessSpec.* must be updated to Reventless.*;
all usages of Reventless.* (core) in dependent packages must be updated to ReventlessCore.*

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
