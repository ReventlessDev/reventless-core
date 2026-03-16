# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# [3.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.7...@reventlessdev/reventless-infra@3.0.0-alpha.8) (2026-03-16)

* feat!: auto-detect plugin version from package.json via V8 stack trace ([e172673](https://github.com/ReventlessDev/reventless-core/commit/e17267390c197fa34052cef8325c579bb781419f))
* feat!: replace Core component with Platform_Admin, rename schema prefix Core_ → Admin_ ([940263d](https://github.com/ReventlessDev/reventless-core/commit/940263d8b39e28f4c874af3b0335ae81444928c4))
### Features

* differentiate ReadModel and StateViewSlice GraphQL query schemas ([62f6130](https://github.com/ReventlessDev/reventless-core/commit/62f6130d2ee34d65fe3eab1395d55c77c0309ddb))
* internalize scheduler, Core, and setup in Platform.makePlatform ([ce3e1b6](https://github.com/ReventlessDev/reventless-core/commit/ce3e1b60e8ffdbab1a6b5cd08d73f5e907726481))

### BREAKING CHANGES

* Plugin.make no longer accepts ~version.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>



# [3.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.6...@reventlessdev/reventless-infra@3.0.0-alpha.7) (2026-03-14)

### Bug Fixes

* eliminate Obj.magic from Platform DcbSpec boundaries ([135888b](https://github.com/ReventlessDev/reventless-core/commit/135888b226727d7ed8cc1e364e242b12071e107a))
### Features

* add optional DCB spec support to Core module and consolidate builder helpers ([06a5e6f](https://github.com/ReventlessDev/reventless-core/commit/06a5e6f2eeadbabd20fb7197318d760b91c34925))


# [3.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.5...@reventlessdev/reventless-infra@3.0.0-alpha.6) (2026-03-12)

### Features

* capitalize and prefix Core_ on GraphQL/MCP queries and mutations ([769420b](https://github.com/ReventlessDev/reventless-core/commit/769420b47ce35aba46d248d1529f7c72c7df9c0e))
* unify schema generation pipeline across GraphQL and MCP protocols ([84e05ae](https://github.com/ReventlessDev/reventless-core/commit/84e05aeca8c13000040d1230502b07350ab5daeb))


# [3.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.4...@reventlessdev/reventless-infra@3.0.0-alpha.5) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))


# [3.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.2...@reventlessdev/reventless-infra@3.0.0-alpha.4) (2026-03-08)

### Bug Fixes

* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add MCP event history resources and fix QueryDb/MCP resource bugs ([3197d4f](https://github.com/ReventlessDev/reventless-core/commit/3197d4fb52a7b20bc68cd3088d9d6fac21a41f6f))
* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))


# [3.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.2...@reventlessdev/reventless-infra@3.0.0-alpha.3) (2026-03-08)

### Bug Fixes

* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add MCP event history resources and fix QueryDb/MCP resource bugs ([3197d4f](https://github.com/ReventlessDev/reventless-core/commit/3197d4fb52a7b20bc68cd3088d9d6fac21a41f6f))
* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))


# [3.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.1...@reventlessdev/reventless-infra@3.0.0-alpha.2) (2026-03-03)

### Features

* **api:** implement Api component with GraphQL fragment generation and schema stitching ([c882d3a](https://github.com/ReventlessDev/reventless-core/commit/c882d3aae8722cf6cbe9b4fbf9518d9f434ce06a))
* **platform:** expose Plugin, Core, makeScheduler, makePlatform via Platform.T ([0df4bf3](https://github.com/ReventlessDev/reventless-core/commit/0df4bf333ea4f9c0e51e96df1ad0da4ab471ffe8))


# 3.0.0-alpha.1 (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-infra
