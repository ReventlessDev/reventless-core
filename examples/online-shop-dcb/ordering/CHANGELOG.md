# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.26 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/online-shop-dcb-ordering





# 1.0.0-alpha.25 (2026-04-24)

### Features

* **gwt:** extract GWT test DSLs into @reventlessdev/reventless-gwt package ([dd64b4e](https://github.com/ReventlessDev/reventless-core/commit/dd64b4e1fd0bb203821d055b6743a52aec1836fb))


# 1.0.0-alpha.24 (2026-04-22)

### Features

* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))


# 1.0.0-alpha.23 (2026-04-20)

### Features

* add automationSlices, translation slices, and extensions to pluginStructure ([631e2f3](https://github.com/ReventlessDev/reventless-core/commit/631e2f3636f0a422e58712f70106c0df8effc1e9))


# 1.0.0-alpha.22 (2026-04-18)

### Features

* **core:** AutoUI definition — makeAutoUIDefinition, Platform_UIDefinitions query, generator support ([513ca53](https://github.com/ReventlessDev/reventless-core/commit/513ca5399b0b6e5ae6a982fd15693de2ea208b8d))
* **core:** uiFragments manifest — Phase 1 implementation with generic types ([1e73f62](https://github.com/ReventlessDev/reventless-core/commit/1e73f623984118081d2b985c48521812e4f8417e))


# 1.0.0-alpha.21 (2026-04-15)

### Features

* zero-touch plugin assembly — generate Plugin.res from folder structure ([73ea654](https://github.com/ReventlessDev/reventless-core/commit/73ea654ab9a73f15ea7e18631e8194bfe0f4580f))


# 1.0.0-alpha.20 (2026-04-07)

### Features

* **ppx+querydb:** annotation-driven key design and sort key queries ([dee6de8](https://github.com/ReventlessDev/reventless-core/commit/dee6de84c2d2de5431d064f18ac7132bc8c23110))
* **ppx:** auto-inject open Reventless.Projection for StateViewSlice files ([ad15b25](https://github.com/ReventlessDev/reventless-core/commit/ad15b253f2645ff2fa790d557734c3ccacb33936))


# 1.0.0-alpha.19 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# 1.0.0-alpha.18 (2026-04-06)

### Features

* implement [@composite](https://github.com/composite)PartitionTag PPX annotation for multi-field DCB partition keys ([cf26b15](https://github.com/ReventlessDev/reventless-core/commit/cf26b15f639d151451c9aa04d32603ef9d5df315))


# 1.0.0-alpha.17 (2026-04-04)

### Bug Fixes

* DCB [@partition](https://github.com/partition)Tag runtime errors, GraphQL Node interface, and ESM config ([dc4c4e1](https://github.com/ReventlessDev/reventless-core/commit/dc4c4e10f1ef09aba840e7b359df453b122c6aa4))
* feat!: add reventless-ppx with @@reventless.spec, @@reventless.behavior, @@reventless.dcbTags ([cb203ec](https://github.com/ReventlessDev/reventless-core/commit/cb203ece5ea3a1b92ba7d1a57d9e12bb6c4c2487))

### BREAKING CHANGES

* Example spec files no longer export manual moduleUrl/name/Id
declarations — these are now PPX-generated. Downstream code referencing these
exports is unaffected (same values, different source).



# 1.0.0-alpha.16 (2026-03-30)

### Features

* **examples:** publish example packages to GitHub Package Registry ([2495ba5](https://github.com/ReventlessDev/reventless-core/commit/2495ba5c4436613d58964f9948c1bacbde61965f))


# [1.0.0-alpha.15](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.13...@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.15) (2026-03-28)

### Bug Fixes

* **examples:** regenerate stale .mjs for aggregate, dcb, and hybrid plugins ([b5b4de5](https://github.com/ReventlessDev/reventless-core/commit/b5b4de5c4db7f5f8eb9071157302c4f0796b1889))
* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))

### BREAKING CHANGES

* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [1.0.0-alpha.14](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.13...@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.14) (2026-03-27)

* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))

### BREAKING CHANGES

* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [1.0.0-alpha.13](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.10...@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.13) (2026-03-27)

* feat!: remove resolverConfig from Behavior module type ([6f54015](https://github.com/ReventlessDev/reventless-core/commit/6f54015e3abc1c5c05472c8f54645723a0f5ed28))
* feat!: decouple DCB slices from shared event log union type ([2a40e8d](https://github.com/ReventlessDev/reventless-core/commit/2a40e8dd9babfb88440fcaccde6fb667b60e0ba9))

### BREAKING CHANGES

* Behavior.T no longer requires resolverConfig. Remove it
from all Behavior implementations.
* All DCB slice specs must use `producedEvent`/`consumedEvent`
instead of `module DcbEventLogSpec`. Plugin `DcbSpec` no longer has `type event`
or `with type dcbEvent` constraints.



# [1.0.0-alpha.12](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.10...@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.12) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-dcb-ordering





# [1.0.0-alpha.11](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.10...@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.11) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-dcb-ordering





# [1.0.0-alpha.10](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.9...@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.10) (2026-03-23)

* refactor!: streamline component function naming to unified two-function pattern ([06814fd](https://github.com/ReventlessDev/reventless-core/commit/06814fd8589cf05ce8a9f9654552e7d5cd9c6bf2))
* fix(reventless-aws)!: resolve DcbEventLogSpec undefined at runtime and add AppSync routing ([85138a3](https://github.com/ReventlessDev/reventless-core/commit/85138a39afe97047ea5f063508994e20544eb780))

### BREAKING CHANGES

* All component function signatures changed. Behavior.decide
now returns result<array<event>, error> instead of using errorHandler callback.
StateChangeSlice type decisionModel renamed to state. Projection.Mapping.map
renamed to project. StateViewSlice.project takes one argument instead of two.

* DcbEventLog.Spec now requires `let moduleUrl: string` field.
Add `let moduleUrl: string = %raw(\`import.meta.url\`)` to event log modules.
# [1.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.8...@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.9) (2026-03-22)

* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [1.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.7...@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.8) (2026-03-16)

* feat!: auto-detect plugin version from package.json via V8 stack trace ([e172673](https://github.com/ReventlessDev/reventless-core/commit/e17267390c197fa34052cef8325c579bb781419f))

### BREAKING CHANGES

* Plugin.make no longer accepts ~version.
# [1.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.6...@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.7) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.5...@reventlessdev/online-shop-dcb-ordering@1.0.0-alpha.6) (2026-03-08)

### Features

* replace explicit queryMode with automatic schema-driven DCB query construction ([8df4350](https://github.com/ReventlessDev/reventless-core/commit/8df4350c37f1f15678f4796f229647eaeb3e8222))
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
