# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 3.0.0-alpha.14 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-catalog-spec





# 3.0.0-alpha.13 (2026-04-22)

### Features

* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))


# 3.0.0-alpha.12 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# 3.0.0-alpha.11 (2026-04-04)

### Bug Fixes

* DCB [@partition](https://github.com/partition)Tag runtime errors, GraphQL Node interface, and ESM config ([dc4c4e1](https://github.com/ReventlessDev/reventless-core/commit/dc4c4e10f1ef09aba840e7b359df453b122c6aa4))
* feat!: add reventless-ppx with @@reventless.spec, @@reventless.behavior, @@reventless.dcbTags ([cb203ec](https://github.com/ReventlessDev/reventless-core/commit/cb203ece5ea3a1b92ba7d1a57d9e12bb6c4c2487))

### BREAKING CHANGES

* Example spec files no longer export manual moduleUrl/name/Id
declarations — these are now PPX-generated. Downstream code referencing these
exports is unaffected (same values, different source).



# 3.0.0-alpha.10 (2026-03-30)

### Features

* **examples:** publish example packages to GitHub Package Registry ([2495ba5](https://github.com/ReventlessDev/reventless-core/commit/2495ba5c4436613d58964f9948c1bacbde61965f))


# [3.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-catalog-spec@3.0.0-alpha.6...@reventlessdev/online-shop-aggregates-catalog-spec@3.0.0-alpha.9) (2026-03-27)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-catalog-spec





# [3.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-catalog-spec@3.0.0-alpha.6...@reventlessdev/online-shop-aggregates-catalog-spec@3.0.0-alpha.8) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-catalog-spec





# [3.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-catalog-spec@3.0.0-alpha.6...@reventlessdev/online-shop-aggregates-catalog-spec@3.0.0-alpha.7) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-catalog-spec





# [3.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-catalog-spec@3.0.0-alpha.5...@reventlessdev/online-shop-aggregates-catalog-spec@3.0.0-alpha.6) (2026-03-22)

* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [3.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-catalog-spec@3.0.0-alpha.4...@reventlessdev/online-shop-aggregates-catalog-spec@3.0.0-alpha.5) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# 3.0.0-alpha.4 (2026-03-08)

### Features

* restructure aggregate example into online-shop-aggregates with spec packages ([5aca927](https://github.com/ReventlessDev/reventless-core/commit/5aca927ba1594940219596307c41f00eebd28f9b))
