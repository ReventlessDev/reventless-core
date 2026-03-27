# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# [1.0.0-alpha.10](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-catalog-spec@1.0.0-alpha.7...@reventlessdev/online-shop-dcb-catalog-spec@1.0.0-alpha.10) (2026-03-27)

* feat!: decouple DCB slices from shared event log union type ([2a40e8d](https://github.com/ReventlessDev/reventless-core/commit/2a40e8dd9babfb88440fcaccde6fb667b60e0ba9))

### BREAKING CHANGES

* All DCB slice specs must use `producedEvent`/`consumedEvent`
instead of `module DcbEventLogSpec`. Plugin `DcbSpec` no longer has `type event`
or `with type dcbEvent` constraints.



# [1.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-catalog-spec@1.0.0-alpha.7...@reventlessdev/online-shop-dcb-catalog-spec@1.0.0-alpha.9) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-dcb-catalog-spec





# [1.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-catalog-spec@1.0.0-alpha.7...@reventlessdev/online-shop-dcb-catalog-spec@1.0.0-alpha.8) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-dcb-catalog-spec





# [1.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-catalog-spec@1.0.0-alpha.6...@reventlessdev/online-shop-dcb-catalog-spec@1.0.0-alpha.7) (2026-03-22)

* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-catalog-spec@1.0.0-alpha.5...@reventlessdev/online-shop-dcb-catalog-spec@1.0.0-alpha.6) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# 1.0.0-alpha.5 (2026-03-08)

### Features

* restructure DCB example into online-shop-dcb with spec packages ([0ee5a10](https://github.com/ReventlessDev/reventless-core/commit/0ee5a10c55248c8e27087f69cdce61a24f98027f))
