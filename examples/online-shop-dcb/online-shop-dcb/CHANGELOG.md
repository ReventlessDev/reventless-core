# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb@1.0.0-alpha.4...@reventlessdev/online-shop-dcb@1.0.0-alpha.5) (2026-03-16)

* feat!: replace Core component with Platform_Admin, rename schema prefix Core_ → Admin_ ([940263d](https://github.com/ReventlessDev/reventless-core/commit/940263d8b39e28f4c874af3b0335ae81444928c4))
### Features

* internalize scheduler, Core, and setup in Platform.makePlatform ([ce3e1b6](https://github.com/ReventlessDev/reventless-core/commit/ce3e1b60e8ffdbab1a6b5cd08d73f5e907726481))
* read version from package.json, make cloner opt-in, log platform version ([d8216a1](https://github.com/ReventlessDev/reventless-core/commit/d8216a1d569064ca14eff6e0c3be86923e5b84ad))

### BREAKING CHANGES

* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>



# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb@1.0.0-alpha.3...@reventlessdev/online-shop-dcb@1.0.0-alpha.4) (2026-03-14)

### Features

* add optional DCB spec support to Core module and consolidate builder helpers ([06a5e6f](https://github.com/ReventlessDev/reventless-core/commit/06a5e6f2eeadbabd20fb7197318d760b91c34925))
* implement hybrid API/MCP schema split (core vs plugins) ([4f84866](https://github.com/ReventlessDev/reventless-core/commit/4f848667c0814533b2f3a294350c4310c61d9fc7))


# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-dcb@1.0.0-alpha.2...@reventlessdev/online-shop-dcb@1.0.0-alpha.3) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))


# 1.0.0-alpha.2 (2026-03-08)

### Features

* restructure DCB example into online-shop-dcb with spec packages ([0ee5a10](https://github.com/ReventlessDev/reventless-core/commit/0ee5a10c55248c8e27087f69cdce61a24f98027f))
