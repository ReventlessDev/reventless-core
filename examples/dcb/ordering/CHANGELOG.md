# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/example-dcb-ordering@1.0.0-alpha.4...@reventlessdev/example-dcb-ordering@1.0.0-alpha.5) (2026-03-03)

### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* **examples:** add example-dcb package with self-assembling DCB plugins ([889a072](https://github.com/ReventlessDev/reventless-core/commit/889a072492967439f9d4692ba9b58cf1bcb01c9d))


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
