# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.26 (2026-05-05)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-platform-in-memory





# 1.0.0-alpha.25 (2026-05-04)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-platform-in-memory





# 1.0.0-alpha.24 (2026-05-03)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-platform-in-memory





# 1.0.0-alpha.23 (2026-05-03)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-platform-in-memory





# 1.0.0-alpha.22 (2026-05-03)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-platform-in-memory





# 1.0.0-alpha.21 (2026-04-28)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-platform-in-memory





# 1.0.0-alpha.20 (2026-04-27)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-platform-in-memory





# 1.0.0-alpha.19 (2026-04-26)

* feat!: mixed-source AutomationSlice — Plan 04 ([fae3fbf](https://github.com/ReventlessDev/reventless-core/commit/fae3fbf93b12ecf62d0883fe7335ed73c6f52d67))

### BREAKING CHANGES

* AutomationSlice.Spec drops consumedEvent;
AutomationSlice_Builder.Make takes Mappings as 3rd arg; make signature
swaps ~dcbEventLog for ~allEventTopics + ~context; Plugin_Builder.Spec
gains platformName. Existing slices need a sibling _Mappings.res file
and updated Plugin.res (regenerate via prebuild hook).

Tests: 362/362 pass. Build clean, zero warnings.

Plan: docs/plans/done/mixed-source-automationslice.md
Guide: docs/guides/mixed-source-automationslice.md



# 1.0.0-alpha.18 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-platform-in-memory





# 1.0.0-alpha.17 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-platform-in-memory





# 1.0.0-alpha.16 (2026-04-22)

### Features

* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))


# 1.0.0-alpha.15 (2026-04-15)

### Features

* zero-touch plugin assembly — generate Plugin.res from folder structure ([73ea654](https://github.com/ReventlessDev/reventless-core/commit/73ea654ab9a73f15ea7e18631e8194bfe0f4580f))


# 1.0.0-alpha.14 (2026-04-13)

### Bug Fixes

* **in-memory:** fix GraphQL schema and resolver bugs in platform servers ([0376941](https://github.com/ReventlessDev/reventless-core/commit/0376941af84501ab9f0b63f1a673e6f510fe3886))


# 1.0.0-alpha.13 (2026-04-12)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates-platform-in-memory





# 1.0.0-alpha.12 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# 1.0.0-alpha.11 (2026-04-06)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates





# 1.0.0-alpha.10 (2026-04-05)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates





# 1.0.0-alpha.9 (2026-04-04)

* feat!: add reventless-ppx with @@reventless.spec, @@reventless.behavior, @@reventless.dcbTags ([cb203ec](https://github.com/ReventlessDev/reventless-core/commit/cb203ece5ea3a1b92ba7d1a57d9e12bb6c4c2487))

### BREAKING CHANGES

* Example spec files no longer export manual moduleUrl/name/Id
declarations — these are now PPX-generated. Downstream code referencing these
exports is unaffected (same values, different source).



# 1.0.0-alpha.8 (2026-03-30)

### Features

* **examples:** publish example packages to GitHub Package Registry ([2495ba5](https://github.com/ReventlessDev/reventless-core/commit/2495ba5c4436613d58964f9948c1bacbde61965f))


# [1.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates@1.0.0-alpha.4...@reventlessdev/online-shop-aggregates@1.0.0-alpha.7) (2026-03-27)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates





# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates@1.0.0-alpha.4...@reventlessdev/online-shop-aggregates@1.0.0-alpha.6) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates





# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates@1.0.0-alpha.4...@reventlessdev/online-shop-aggregates@1.0.0-alpha.5) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-aggregates





# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates@1.0.0-alpha.3...@reventlessdev/online-shop-aggregates@1.0.0-alpha.4) (2026-03-16)

* feat!: replace Core component with Platform_Admin, rename schema prefix Core_ → Admin_ ([940263d](https://github.com/ReventlessDev/reventless-core/commit/940263d8b39e28f4c874af3b0335ae81444928c4))
### Features

* internalize scheduler, Core, and setup in Platform.makePlatform ([ce3e1b6](https://github.com/ReventlessDev/reventless-core/commit/ce3e1b60e8ffdbab1a6b5cd08d73f5e907726481))
* read version from package.json, make cloner opt-in, log platform version ([d8216a1](https://github.com/ReventlessDev/reventless-core/commit/d8216a1d569064ca14eff6e0c3be86923e5b84ad))

### BREAKING CHANGES

* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.
# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-aggregates@1.0.0-alpha.2...@reventlessdev/online-shop-aggregates@1.0.0-alpha.3) (2026-03-14)

### Features

* add optional DCB spec support to Core module and consolidate builder helpers ([06a5e6f](https://github.com/ReventlessDev/reventless-core/commit/06a5e6f2eeadbabd20fb7197318d760b91c34925))
# 1.0.0-alpha.2 (2026-03-08)

### Features

* restructure aggregate example into online-shop-aggregates with spec packages ([5aca927](https://github.com/ReventlessDev/reventless-core/commit/5aca927ba1594940219596307c41f00eebd28f9b))
* restructure DCB example into online-shop-dcb with spec packages ([0ee5a10](https://github.com/ReventlessDev/reventless-core/commit/0ee5a10c55248c8e27087f69cdce61a24f98027f))
