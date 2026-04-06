# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.14 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# 1.0.0-alpha.13 (2026-04-06)

### Dependency Updates

* **@reventlessdev/online-shop-hybrid-catalog** updated to `^1.0.0-alpha.13`
* **@reventlessdev/online-shop-hybrid-ordering** updated to `^1.0.0-alpha.12`


# 1.0.0-alpha.12 (2026-04-05)

### Dependency Updates

* **@reventlessdev/online-shop-hybrid-catalog** updated to `^1.0.0-alpha.12`
* **@reventlessdev/online-shop-hybrid-ordering** updated to `^1.0.0-alpha.11`


# 1.0.0-alpha.11 (2026-04-04)

### Features

* migrate online-shop-hybrid example to reventless-ppx ([ac66980](https://github.com/ReventlessDev/reventless-core/commit/ac669807bf94b061b85e0217f1ec76af50d12a44))


# 1.0.0-alpha.10 (2026-04-03)

### Dependency Updates

* **@reventlessdev/online-shop-hybrid-catalog** updated to `^1.0.0-alpha.10`


# 1.0.0-alpha.9 (2026-03-30)

### Features

* **examples:** publish example packages to GitHub Package Registry ([2495ba5](https://github.com/ReventlessDev/reventless-core/commit/2495ba5c4436613d58964f9948c1bacbde61965f))


# [1.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.6...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.8) (2026-03-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform





# [1.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.6...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.7) (2026-03-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform





# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.3...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.6) (2026-03-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform





# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.3...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.5) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform





# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.3...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.4) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform





# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.2...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.3) (2026-03-23)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform

# [1.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.1...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.2) (2026-03-22)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform

# 1.0.0-alpha.1 (2026-03-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform

# [1.0.0-alpha.0](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid@0.1.0-alpha.2...@reventlessdev/online-shop-hybrid@1.0.0-alpha.0) (2026-03-16)

* feat!: replace Core component with Platform_Admin, rename schema prefix Core_ → Admin_ ([940263d](https://github.com/ReventlessDev/reventless-core/commit/940263d8b39e28f4c874af3b0335ae81444928c4))
### Features

* internalize scheduler, Core, and setup in Platform.makePlatform ([ce3e1b6](https://github.com/ReventlessDev/reventless-core/commit/ce3e1b60e8ffdbab1a6b5cd08d73f5e907726481))
* read version from package.json, make cloner opt-in, log platform version ([d8216a1](https://github.com/ReventlessDev/reventless-core/commit/d8216a1d569064ca14eff6e0c3be86923e5b84ad))

### BREAKING CHANGES

* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.
# [0.1.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid@0.1.0-alpha.1...@reventlessdev/online-shop-hybrid@0.1.0-alpha.2) (2026-03-14)

### Features

* add optional DCB spec support to Core module and consolidate builder helpers ([06a5e6f](https://github.com/ReventlessDev/reventless-core/commit/06a5e6f2eeadbabd20fb7197318d760b91c34925))
# [0.1.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid@0.1.0-alpha.0...@reventlessdev/online-shop-hybrid@0.1.0-alpha.1) (2026-03-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid

# 0.1.0-alpha.0 (2026-03-08)

### Features

* **examples:** add online-shop-hybrid example with aggregate + DCB composition ([296ad05](https://github.com/ReventlessDev/reventless-core/commit/296ad05f067c53854d4cf0a5d4a8deb91d751b04))
