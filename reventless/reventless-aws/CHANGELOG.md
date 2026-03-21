# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# [3.0.0-alpha.18](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.17...@reventlessdev/reventless-aws@3.0.0-alpha.18) (2026-03-21)

### Bug Fixes

* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))


# [3.0.0-alpha.17](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.16...@reventlessdev/reventless-aws@3.0.0-alpha.17) (2026-03-20)

### Bug Fixes

* **aws:** make Lambda bundling deterministic to prevent unnecessary redeploys ([049abcd](https://github.com/ReventlessDev/reventless-core/commit/049abcd07e1dd5bc7270a6dd376d57963a2ce841))
* **aws:** reduce Lambda bundle size by externalizing layer packages ([c1a042a](https://github.com/ReventlessDev/reventless-core/commit/c1a042a8304bd303a4e0018954b239e9ec38d2bf))
### Features

* **aws:** add Lambda FunctionUrl bindings and AWS split-api integration tests ([07c7cbe](https://github.com/ReventlessDev/reventless-core/commit/07c7cbeb688cfa8e48d92d7ff37738312493b00a))
* **aws:** export platform component outputs and build admin Plugin aggregate/read model ([fabc069](https://github.com/ReventlessDev/reventless-core/commit/fabc069233dcf07c4eba8934868117bfe92ad59a))
* **aws:** expose api/apiRole in Platform.T and remove unused MakeBundled modules ([a3be4cc](https://github.com/ReventlessDev/reventless-core/commit/a3be4cc5dc6041fb70c8e44a9e48f0a4f730242a))
* **aws:** implement bundled DCB CommandTopic, Heartbeat, and EP fix ([4ae72ec](https://github.com/ReventlessDev/reventless-core/commit/4ae72ec20d7ea1941e9b02dc7f06461c5fff06c4))
* **aws:** implement split API and fix bundled handler issues ([a3dfa79](https://github.com/ReventlessDev/reventless-core/commit/a3dfa79612eca4c4f57fabac7768f7bbda511eae))
* **aws:** replace CallbackFunction with bundled Lambda handlers ([6f6200b](https://github.com/ReventlessDev/reventless-core/commit/6f6200b0796e5f414493f50fd2f13dd6c7871ef4))
* **interop:** add component-level resolved output types and export plugin outputs from deployPlugin ([b502cbf](https://github.com/ReventlessDev/reventless-core/commit/b502cbf189f024f8bb3fd19a75bf5d76c7de2236))


# [3.0.0-alpha.16](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.15...@reventlessdev/reventless-aws@3.0.0-alpha.16) (2026-03-17)

### Bug Fixes

* add @aws-sdk/client-appsync dep and fix ESM Component import ([aec0dcd](https://github.com/ReventlessDev/reventless-core/commit/aec0dcd73787ed9d988223c72ffd82d423f834a5))
* **reventless-aws:** resolve Pulumi deploy-time issues ([f0ce675](https://github.com/ReventlessDev/reventless-core/commit/f0ce6751cb3ac829c674991784c5f23cb45a991b))
### Features

* **reventless-aws:** implement per-plugin deployment with runtime schema stitching ([f16714c](https://github.com/ReventlessDev/reventless-core/commit/f16714c5d2b3ad869863ac30dc55ef3e1570bf4f))


# [3.0.0-alpha.15](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.14...@reventlessdev/reventless-aws@3.0.0-alpha.15) (2026-03-16)

* feat!: unify DCB and Aggregate command generation paths ([8c9bbad](https://github.com/ReventlessDev/reventless-core/commit/8c9bbad14082e7b696da35f5abb337520b1c8683))
* feat!: replace Core component with Platform_Admin, rename schema prefix Core_ → Admin_ ([940263d](https://github.com/ReventlessDev/reventless-core/commit/940263d8b39e28f4c874af3b0335ae81444928c4))
### Features

* internalize scheduler, Core, and setup in Platform.makePlatform ([ce3e1b6](https://github.com/ReventlessDev/reventless-core/commit/ce3e1b60e8ffdbab1a6b5cd08d73f5e907726481))
* read version from package.json, make cloner opt-in, log platform version ([d8216a1](https://github.com/ReventlessDev/reventless-core/commit/d8216a1d569064ca14eff6e0c3be86923e5b84ad))

### BREAKING CHANGES

* DCB mutation return value changes from "ok" to a UUID.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>



# [3.0.0-alpha.14](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.13...@reventlessdev/reventless-aws@3.0.0-alpha.14) (2026-03-14)

### Bug Fixes

* eliminate Obj.magic from Platform DcbSpec boundaries ([135888b](https://github.com/ReventlessDev/reventless-core/commit/135888b226727d7ed8cc1e364e242b12071e107a))
### Features

* add optional DCB spec support to Core module and consolidate builder helpers ([06a5e6f](https://github.com/ReventlessDev/reventless-core/commit/06a5e6f2eeadbabd20fb7197318d760b91c34925))
* implement hybrid API/MCP schema split (core vs plugins) ([4f84866](https://github.com/ReventlessDev/reventless-core/commit/4f848667c0814533b2f3a294350c4310c61d9fc7))


# [3.0.0-alpha.13](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.12...@reventlessdev/reventless-aws@3.0.0-alpha.13) (2026-03-12)

### Features

* capitalize and prefix Core_ on GraphQL/MCP queries and mutations ([769420b](https://github.com/ReventlessDev/reventless-core/commit/769420b47ce35aba46d248d1529f7c72c7df9c0e))
* unify schema generation pipeline across GraphQL and MCP protocols ([84e05ae](https://github.com/ReventlessDev/reventless-core/commit/84e05aeca8c13000040d1230502b07350ab5daeb))


# [3.0.0-alpha.12](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.11...@reventlessdev/reventless-aws@3.0.0-alpha.12) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))


# [3.0.0-alpha.11](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.9...@reventlessdev/reventless-aws@3.0.0-alpha.11) (2026-03-08)

### Bug Fixes

* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add AWS event history handlers and pagination for MCP resources ([33f6e39](https://github.com/ReventlessDev/reventless-core/commit/33f6e3910d50cfbe03c9d2d2ed2ea97b92ab7501))
* add effect-based handlers with Effect service injection at dispatch ([7ab3b3e](https://github.com/ReventlessDev/reventless-core/commit/7ab3b3e8a48890f2248b113328914755f604c07e))
* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* auto-generate GraphQL mutations for InboundTranslationSlice ([7011fd2](https://github.com/ReventlessDev/reventless-core/commit/7011fd29f3029f001aa94fa78eb4f6b34d45451e))
* fix GraphQL SDL generation — correct naming, typed returns, and aggregate mutations ([ac93318](https://github.com/ReventlessDev/reventless-core/commit/ac933182dcd238b5f02ed98d1ddf03bb52b2c109))
* harmonize error handling and retry with Effect across all AWS adapters ([a817bde](https://github.com/ReventlessDev/reventless-core/commit/a817bde2fbbda314ebdbc69aee17de717ee059ed))
* lift AWS runtime handlers into pure Effect pipelines ([136f1c0](https://github.com/ReventlessDev/reventless-core/commit/136f1c0712a65e46d4be292c42b1d02babcc2f1b))
* make Logger injectable at Platform level and replace Console.log in runtime builders ([5c5dd5b](https://github.com/ReventlessDev/reventless-core/commit/5c5dd5bc07c14c13a9fc5d857d26387e14d06dd6))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))
* replace timestamp-based sequenceNr with integer sequence numbers and optimistic locking ([50b7d3e](https://github.com/ReventlessDev/reventless-core/commit/50b7d3e9901daafc6dff8c9492a789bc700e9099))


# [3.0.0-alpha.10](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.9...@reventlessdev/reventless-aws@3.0.0-alpha.10) (2026-03-08)

### Bug Fixes

* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add AWS event history handlers and pagination for MCP resources ([33f6e39](https://github.com/ReventlessDev/reventless-core/commit/33f6e3910d50cfbe03c9d2d2ed2ea97b92ab7501))
* add effect-based handlers with Effect service injection at dispatch ([7ab3b3e](https://github.com/ReventlessDev/reventless-core/commit/7ab3b3e8a48890f2248b113328914755f604c07e))
* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* auto-generate GraphQL mutations for InboundTranslationSlice ([7011fd2](https://github.com/ReventlessDev/reventless-core/commit/7011fd29f3029f001aa94fa78eb4f6b34d45451e))
* fix GraphQL SDL generation — correct naming, typed returns, and aggregate mutations ([ac93318](https://github.com/ReventlessDev/reventless-core/commit/ac933182dcd238b5f02ed98d1ddf03bb52b2c109))
* harmonize error handling and retry with Effect across all AWS adapters ([a817bde](https://github.com/ReventlessDev/reventless-core/commit/a817bde2fbbda314ebdbc69aee17de717ee059ed))
* lift AWS runtime handlers into pure Effect pipelines ([136f1c0](https://github.com/ReventlessDev/reventless-core/commit/136f1c0712a65e46d4be292c42b1d02babcc2f1b))
* make Logger injectable at Platform level and replace Console.log in runtime builders ([5c5dd5b](https://github.com/ReventlessDev/reventless-core/commit/5c5dd5bc07c14c13a9fc5d857d26387e14d06dd6))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))


# [3.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.8...@reventlessdev/reventless-aws@3.0.0-alpha.9) (2026-03-03)

### Features

* **api:** implement Api component with GraphQL fragment generation and schema stitching ([c882d3a](https://github.com/ReventlessDev/reventless-core/commit/c882d3aae8722cf6cbe9b4fbf9518d9f434ce06a))
* **platform:** expose Plugin, Core, makeScheduler, makePlatform via Platform.T ([0df4bf3](https://github.com/ReventlessDev/reventless-core/commit/0df4bf333ea4f9c0e51e96df1ad0da4ab471ffe8))


# [3.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.7...@reventlessdev/reventless-aws@3.0.0-alpha.8) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# [3.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.6...@reventlessdev/reventless-aws@3.0.0-alpha.7) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# [3.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.5...@reventlessdev/reventless-aws@3.0.0-alpha.6) (2026-03-01)

* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))
* feat(reventless-core)!: rename package from @reventlessdev/reventless to @reventlessdev/reventless-core ([5e93146](https://github.com/ReventlessDev/reventless-core/commit/5e9314692b5b5d60beee187564ba94bc9fd46c05))
### Features

* **rescript-effect:** Effect library bindings + stream-based framework handlers ([#30](https://github.com/ReventlessDev/reventless-core/issues/30)) ([f2ca5cf](https://github.com/ReventlessDev/reventless-core/commit/f2ca5cf3d56d66a9f4ab56b543d7bf82e48448dd))
* **reventless-aws:** implement AWS StateViewSlice_Builder with DynamoDB/AppSync adapters ([04cc0f3](https://github.com/ReventlessDev/reventless-core/commit/04cc0f351ec4d8d18ec6eae8a7b81783ed9ecb83))

### BREAKING CHANGES

* ReventlessSpec namespace renamed to Reventless; the reventless-core
package namespace renamed from Reventless to ReventlessCore.
All usages of ReventlessSpec.* must be updated to Reventless.*;
all usages of Reventless.* (core) in dependent packages must be updated to ReventlessCore.*

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
* package renamed for consistency with sibling packages
and the repository name. ReScript namespace "Reventless" is unchanged —
no source code updates required.

- git mv reventless/reventless → reventless/reventless-core
- package.json and rescript.json name updated to @reventlessdev/reventless-core
- reventless-aws and reventless-in-memory dependency references updated
- Root package.json and rescript.json renamed to "reventless-monorepo" to
  avoid name collision that caused ReScript to skip building the sub-package
- Updated recompiled .res.mjs output files with new relative import paths

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>



# [3.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.4...@reventlessdev/reventless-aws@3.0.0-alpha.5) (2026-02-18)

### Bug Fixes

* **dcb:** update js file and update uuid dependency ([b6e68e7](https://github.com/ReventlessDev/reventless-core/commit/b6e68e7c05d1c763ab2ccee3269e05c5362a82b6))
### Features

* **dcb:** add DynamoDB adapter with dynamic GSI generation ([820aa82](https://github.com/ReventlessDev/reventless-core/commit/820aa82e116774c77bf3abdb2228232e67cfa4c3))
* **dcb:** integrate DCB into Plugin component ([f44c2bf](https://github.com/ReventlessDev/reventless-core/commit/f44c2bf21d13a22c64e1b49829d04ebe34aece71))
* **dcb:** shared event log and schema-based command routing per plugin ([2464ae4](https://github.com/ReventlessDev/reventless-core/commit/2464ae41f589cc0a224de2f81e186091700d91ee))


# [3.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.3...@reventlessdev/reventless-aws@3.0.0-alpha.4) (2026-02-14)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# [3.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.2...@reventlessdev/reventless-aws@3.0.0-alpha.3) (2026-02-13)

* refactor!: remove AWS dependencies from reventless core package ([bc2c4af](https://github.com/ReventlessDev/reventless-core/commit/bc2c4aff85af4f83b9d131584845260b060db647))

### BREAKING CHANGES

* Builder functions now require explicit resourceNaming and runtimeOps parameters

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>



# [3.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.1...@reventlessdev/reventless-aws@3.0.0-alpha.2) (2026-02-12)


### Bug Fixes

* remove all ReScript compiler warnings across packages ([a943a21](https://github.com/ReventlessDev/reventless-core/commit/a943a2107aac1a2b27a72ffe3aab9bd15e61b6c0))





# [3.0.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.0...@reventlessdev/reventless-aws@3.0.0-alpha.1) (2026-02-12)


### Bug Fixes

* exclude private packages from versioning and automate doc CHANGELOG updates ([7581d78](https://github.com/ReventlessDev/reventless-core/commit/7581d78e9825fa6d837da8a136b361dee821660f))





# 3.0.0-alpha.0 (2026-02-12)


### Bug Fixes

* **publish:** add publishConfig to packages for GitHub Package Registry ([987a00a](https://github.com/ReventlessDev/reventless-core/commit/987a00af049fed112aa91fd53d8fad719cd80c94))


### Code Refactoring

* rename Behaviour to Behavior (British to American spelling) ([6575f44](https://github.com/ReventlessDev/reventless-core/commit/6575f4415fa0fb27472f3520038f158dd624da03))


### Reverts

* Revert "reventless-aws: configure QueryEngine_DynamoDb to use ConsistentRead" ([9bd8457](https://github.com/ReventlessDev/reventless-core/commit/9bd84579973a5ff5cf0e3a8902dbd341c696c1fd))
* Revert "reventless & reventless-aws: add lambdas to component resources array (#101)" ([ee1e03f](https://github.com/ReventlessDev/reventless-core/commit/ee1e03fed9c95a055f22814f545e0046fc2fa044)), closes [#101](https://github.com/ReventlessDev/reventless-core/issues/101)
* Revert "wrap Lambda.CallbackFunction param policies into Pulumi.Input" ([b023c23](https://github.com/ReventlessDev/reventless-core/commit/b023c23ef8f252b00796a062826daabd519f7cac))
* Revert "reventless-aws: add func resource to CommandGenerator, CommandTopic, Counter, EventCollector adapters" ([2b287ba](https://github.com/ReventlessDev/reventless-core/commit/2b287ba446dabfa9d78c3bcd8de49abfea84b0ba))


### BREAKING CHANGES

* All references to Behaviour module must be updated to Behavior
