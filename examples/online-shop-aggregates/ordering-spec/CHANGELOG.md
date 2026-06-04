# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 3.0.0-alpha.44 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.43 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.42 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.41 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.40 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.39 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.38 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.37 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.36 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.35 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.34 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.33 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.32 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.31 (2026-05-20)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.30 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.29 (2026-05-18)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.28 (2026-05-17)

### Bug Fixes

* **deps:** pin sury-ppx to 11.0.0-alpha.2 to prevent prerelease drift ([c9d05fe](https://github.com/ReventlessDev/reventless-core/commit/c9d05fe5118a9c0442ca3e071f2606b3a139fc81))


# 3.0.0-alpha.27 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.26 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.25 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.24 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.23 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.22 (2026-05-14)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.21 (2026-05-13)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.20 (2026-05-05)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.19 (2026-05-03)

* refactor(examples)!: migrate online-shop-aggregates to new naming + adopt new PPX ([9dac635](https://github.com/ReventlessDev/reventless-core/commit/9dac6353b88e6c6bba88d1ce9d4a0594be976f62))

### BREAKING CHANGES

* external code consuming the
`@reventlessdev/online-shop-aggregates-*` packages must update module name
references (e.g., `CategoriesReadModel` → `Categories`,
`ProductsExtensionPoint` → `Products_ExtensionPoint`, `CategoryBehavior` →
`Category_Behavior`).

Verified: zero warnings, 1174/1175 tests pass — same single pre-existing
testPromise race in OrderingE2ETest as PR1/PR2.



# 3.0.0-alpha.18 (2026-04-28)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.17 (2026-04-27)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.16 (2026-04-26)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.15 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# 3.0.0-alpha.14 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





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


# [3.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-ordering-spec@3.0.0-alpha.6...@reventlessdev/online-shop-aggregates-ordering-spec@3.0.0-alpha.9) (2026-03-27)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# [3.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-ordering-spec@3.0.0-alpha.6...@reventlessdev/online-shop-aggregates-ordering-spec@3.0.0-alpha.8) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# [3.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-ordering-spec@3.0.0-alpha.6...@reventlessdev/online-shop-aggregates-ordering-spec@3.0.0-alpha.7) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-ordering-spec





# [3.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-ordering-spec@3.0.0-alpha.5...@reventlessdev/online-shop-aggregates-ordering-spec@3.0.0-alpha.6) (2026-03-22)

* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [3.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates-ordering-spec@3.0.0-alpha.4...@reventlessdev/online-shop-aggregates-ordering-spec@3.0.0-alpha.5) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# 3.0.0-alpha.4 (2026-03-08)

### Features

* restructure aggregate example into online-shop-aggregates with spec packages ([5aca927](https://github.com/ReventlessDev/reventless-core/commit/5aca927ba1594940219596307c41f00eebd28f9b))
