# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 3.0.0-alpha.34 (2026-04-15)

### Dependency Updates

* **@reventlessdev/reventless-spec** updated to `^3.0.0-alpha.26`


# 3.0.0-alpha.33 (2026-04-15)

### Features

* zero-touch plugin assembly — generate Plugin.res from folder structure ([73ea654](https://github.com/ReventlessDev/reventless-core/commit/73ea654ab9a73f15ea7e18631e8194bfe0f4580f))


# 3.0.0-alpha.32 (2026-04-13)

### Features

* **api:** generate By{Index} query fields in SDL for GSI resolvers ([46681b3](https://github.com/ReventlessDev/reventless-core/commit/46681b3ecf2877a1cb6b8459547e014cba0c1f41))


# 3.0.0-alpha.31 (2026-04-12)

### Features

* **platform:** MakeAsync opt-in for aggregates and DCB slices ([6970d88](https://github.com/ReventlessDev/reventless-core/commit/6970d889fa05e738dbda5d8e450a1dcf927b23b7))
* **platform:** symmetric domain/platform server architecture (Phase 6) ([4bbc88d](https://github.com/ReventlessDev/reventless-core/commit/4bbc88d2dac3b0d3a6099008f3814d6aedf03e29))


# 3.0.0-alpha.30 (2026-04-11)

### Features

* **platform:** add apiTarget routing for deployPlugin (Phase 4a-4d) ([b9b2d75](https://github.com/ReventlessDev/reventless-core/commit/b9b2d754c2fb61854fc5bca8761a0d0acfb89009))


# 3.0.0-alpha.29 (2026-04-09)

### Features

* **ppx:** implement [@no](https://github.com/no)Api to exclude commands from GraphQL/MCP exposure ([079b686](https://github.com/ReventlessDev/reventless-core/commit/079b68693976a53f8094f1233ebf8b67a86a65c0))


# 3.0.0-alpha.28 (2026-04-07)

### Dependency Updates

* **@reventlessdev/reventless-spec** updated to `^3.0.0-alpha.23`


# 3.0.0-alpha.27 (2026-04-07)

### Features

* **ppx+querydb:** annotation-driven key design and sort key queries ([dee6de8](https://github.com/ReventlessDev/reventless-core/commit/dee6de84c2d2de5431d064f18ac7132bc8c23110))


# 3.0.0-alpha.26 (2026-04-07)

### Dependency Updates

* **@reventlessdev/reventless-spec** updated to `^3.0.0-alpha.21`


# 3.0.0-alpha.25 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# 3.0.0-alpha.24 (2026-04-06)

### Dependency Updates

* **@reventlessdev/reventless-spec** updated to `^3.0.0-alpha.19`


# 3.0.0-alpha.23 (2026-04-04)

* feat!: add reventless-ppx with @@reventless.spec, @@reventless.behavior, @@reventless.dcbTags ([cb203ec](https://github.com/ReventlessDev/reventless-core/commit/cb203ece5ea3a1b92ba7d1a57d9e12bb6c4c2487))
* feat!: Extension Blueprint pattern with auto-merge and plugin naming ([0856d4d](https://github.com/ReventlessDev/reventless-core/commit/0856d4d2a23b8d5175fd091f90110d4c44927191))
### Features

* add Relay server compliance to GraphQL API ([bd9245d](https://github.com/ReventlessDev/reventless-core/commit/bd9245da87023247643c5fa37cee21b0cde0f61e))

### BREAKING CHANGES

* Example spec files no longer export manual moduleUrl/name/Id
declarations — these are now PPX-generated. Downstream code referencing these
exports is unaffected (same values, different source).
* Platform.Extension.Make returns Extension.Blueprint
instead of Extension.T. Plugin.make ~extensions param type changes
accordingly. Make2/Make3/MakeMulti removed from Platform.T.



# 3.0.0-alpha.22 (2026-04-03)

* feat!: support multi-command returns in InboundTranslationSlice ([eaac621](https://github.com/ReventlessDev/reventless-core/commit/eaac6213829b876db508b6a98db081ee40dc3e95))

### BREAKING CHANGES

* All `translate` implementations must wrap returns in arrays.



# 3.0.0-alpha.21 (2026-04-02)

### Features

* add tags field to resource and resolvedResource records ([18911e6](https://github.com/ReventlessDev/reventless-core/commit/18911e66aa94e60d4a9b72ba1d1ca84dd3fb1a9f))


# 3.0.0-alpha.20 (2026-04-02)

* feat!: add deploy lifecycle hooks, enrich resource metadata, and add Adapter.make factory ([0a171f4](https://github.com/ReventlessDev/reventless-core/commit/0a171f4b8aec0ee47fd7ee5069adf5d5b194548e))

### BREAKING CHANGES

* Adapter.resource.info replaced with resourceInfo variant type.
Service field values now prefixed with provider namespace (e.g. "aws:DynamoDb").
New required fields on resource/resolvedResource: role, region, resourceType, configuration.



# 3.0.0-alpha.19 (2026-03-31)

### Features

* return Plugin.outputs from deployPlugin ([22e59f7](https://github.com/ReventlessDev/reventless-core/commit/22e59f730c5c87dd0e3e8d4cf225d401298759f8))


# [3.0.0-alpha.18](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.17...@reventlessdev/reventless-infra@3.0.0-alpha.18) (2026-03-30)

### Features

* unified logging with structured output, colored levels, and CloudWatch detail ([7754cf1](https://github.com/ReventlessDev/reventless-core/commit/7754cf11037b17fce01ab65c2c906d9faf7ac4b6))


# [3.0.0-alpha.17](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.15...@reventlessdev/reventless-infra@3.0.0-alpha.17) (2026-03-28)

* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))

### BREAKING CHANGES

* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [3.0.0-alpha.16](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.15...@reventlessdev/reventless-infra@3.0.0-alpha.16) (2026-03-27)

* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))

### BREAKING CHANGES

* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [3.0.0-alpha.15](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.12...@reventlessdev/reventless-infra@3.0.0-alpha.15) (2026-03-27)

* feat!: decouple DCB slices from shared event log union type ([2a40e8d](https://github.com/ReventlessDev/reventless-core/commit/2a40e8dd9babfb88440fcaccde6fb667b60e0ba9))

### BREAKING CHANGES

* All DCB slice specs must use `producedEvent`/`consumedEvent`
instead of `module DcbEventLogSpec`. Plugin `DcbSpec` no longer has `type event`
or `with type dcbEvent` constraints.



# [3.0.0-alpha.14](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.12...@reventlessdev/reventless-infra@3.0.0-alpha.14) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/reventless-infra





# [3.0.0-alpha.13](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.12...@reventlessdev/reventless-infra@3.0.0-alpha.13) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/reventless-infra





# [3.0.0-alpha.12](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.11...@reventlessdev/reventless-infra@3.0.0-alpha.12) (2026-03-23)

**Note:** Version bump only for package @reventlessdev/reventless-infra

# [3.0.0-alpha.11](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.10...@reventlessdev/reventless-infra@3.0.0-alpha.11) (2026-03-22)

* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [3.0.0-alpha.10](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.9...@reventlessdev/reventless-infra@3.0.0-alpha.10) (2026-03-20)

### Features

* **aws:** expose api/apiRole in Platform.T and remove unused MakeBundled modules ([a3be4cc](https://github.com/ReventlessDev/reventless-core/commit/a3be4cc5dc6041fb70c8e44a9e48f0a4f730242a))
* **aws:** replace CallbackFunction with bundled Lambda handlers ([6f6200b](https://github.com/ReventlessDev/reventless-core/commit/6f6200b0796e5f414493f50fd2f13dd6c7871ef4))
# [3.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.8...@reventlessdev/reventless-infra@3.0.0-alpha.9) (2026-03-17)

### Bug Fixes

* add @aws-sdk/client-appsync dep and fix ESM Component import ([aec0dcd](https://github.com/ReventlessDev/reventless-core/commit/aec0dcd73787ed9d988223c72ffd82d423f834a5))
### Features

* **reventless-aws:** implement per-plugin deployment with runtime schema stitching ([f16714c](https://github.com/ReventlessDev/reventless-core/commit/f16714c5d2b3ad869863ac30dc55ef3e1570bf4f))
# [3.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-infra@3.0.0-alpha.7...@reventlessdev/reventless-infra@3.0.0-alpha.8) (2026-03-16)

* feat!: auto-detect plugin version from package.json via V8 stack trace ([e172673](https://github.com/ReventlessDev/reventless-core/commit/e17267390c197fa34052cef8325c579bb781419f))
* feat!: replace Core component with Platform_Admin, rename schema prefix Core_ → Admin_ ([940263d](https://github.com/ReventlessDev/reventless-core/commit/940263d8b39e28f4c874af3b0335ae81444928c4))
### Features

* differentiate ReadModel and StateViewSlice GraphQL query schemas ([62f6130](https://github.com/ReventlessDev/reventless-core/commit/62f6130d2ee34d65fe3eab1395d55c77c0309ddb))
* internalize scheduler, Core, and setup in Platform.makePlatform ([ce3e1b6](https://github.com/ReventlessDev/reventless-core/commit/ce3e1b60e8ffdbab1a6b5cd08d73f5e907726481))

### BREAKING CHANGES

* Plugin.make no longer accepts ~version.

* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.
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
