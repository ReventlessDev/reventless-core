# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.12 (2026-04-04)

### Bug Fixes

* DCB [@partition](https://github.com/partition)Tag runtime errors, GraphQL Node interface, and ESM config ([dc4c4e1](https://github.com/ReventlessDev/reventless-core/commit/dc4c4e10f1ef09aba840e7b359df453b122c6aa4))
* feat!: add reventless-ppx with @@reventless.spec, @@reventless.behavior, @@reventless.dcbTags ([cb203ec](https://github.com/ReventlessDev/reventless-core/commit/cb203ece5ea3a1b92ba7d1a57d9e12bb6c4c2487))

### BREAKING CHANGES

* Example spec files no longer export manual moduleUrl/name/Id
declarations — these are now PPX-generated. Downstream code referencing these
exports is unaffected (same values, different source).



# 1.0.0-alpha.11 (2026-03-30)

### Features

* **examples:** publish example packages to GitHub Package Registry ([2495ba5](https://github.com/ReventlessDev/reventless-core/commit/2495ba5c4436613d58964f9948c1bacbde61965f))


# [1.0.0-alpha.10](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering-spec@1.0.0-alpha.7...@reventlessdev/online-shop-dcb-ordering-spec@1.0.0-alpha.10) (2026-03-27)

* feat!: decouple DCB slices from shared event log union type ([2a40e8d](https://github.com/ReventlessDev/reventless-core/commit/2a40e8dd9babfb88440fcaccde6fb667b60e0ba9))

### BREAKING CHANGES

* All DCB slice specs must use `producedEvent`/`consumedEvent`
instead of `module DcbEventLogSpec`. Plugin `DcbSpec` no longer has `type event`
or `with type dcbEvent` constraints.



# [1.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering-spec@1.0.0-alpha.7...@reventlessdev/online-shop-dcb-ordering-spec@1.0.0-alpha.9) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-dcb-ordering-spec





# [1.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering-spec@1.0.0-alpha.7...@reventlessdev/online-shop-dcb-ordering-spec@1.0.0-alpha.8) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-dcb-ordering-spec





# [1.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering-spec@1.0.0-alpha.6...@reventlessdev/online-shop-dcb-ordering-spec@1.0.0-alpha.7) (2026-03-22)

* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb-ordering-spec@1.0.0-alpha.5...@reventlessdev/online-shop-dcb-ordering-spec@1.0.0-alpha.6) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# 1.0.0-alpha.5 (2026-03-08)

### Features

* restructure DCB example into online-shop-dcb with spec packages ([0ee5a10](https://github.com/ReventlessDev/reventless-core/commit/0ee5a10c55248c8e27087f69cdce61a24f98027f))
