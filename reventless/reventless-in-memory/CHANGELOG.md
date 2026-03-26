# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# [1.0.0-alpha.16](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.15...@reventlessdev/reventless-in-memory@1.0.0-alpha.16) (2026-03-26)

### Bug Fixes

* conditionally exclude ID parameter from StateViewSlice GraphQL queries ([43de4b6](https://github.com/ReventlessDev/reventless-core/commit/43de4b667d89235ea03b3e1584070515e10e71de))
* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [1.0.0-alpha.15](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.14...@reventlessdev/reventless-in-memory@1.0.0-alpha.15) (2026-03-23)

* refactor!: streamline component function naming to unified two-function pattern ([06814fd](https://github.com/ReventlessDev/reventless-core/commit/06814fd8589cf05ce8a9f9654552e7d5cd9c6bf2))
* fix(reventless-aws)!: fix DcbEventLog DynamoDB stream event decoding and normalize field names ([c83d38a](https://github.com/ReventlessDev/reventless-core/commit/c83d38abbeb225cf68fdc22a0210da46f249a558))
* fix(reventless-aws)!: resolve DcbEventLogSpec undefined at runtime and add AppSync routing ([85138a3](https://github.com/ReventlessDev/reventless-core/commit/85138a39afe97047ea5f063508994e20544eb780))

### BREAKING CHANGES

* All component function signatures changed. Behavior.decide
now returns result<array<event>, error> instead of using errorHandler callback.
StateChangeSlice type decisionModel renamed to state. Projection.Mapping.map
renamed to project. StateViewSlice.project takes one argument instead of two.

* DynamoDB attribute names changed. Existing event log tables require migration.

* DcbEventLog.Spec now requires `let moduleUrl: string` field.
Add `let moduleUrl: string = %raw(\`import.meta.url\`)` to event log modules.
# [1.0.0-alpha.14](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.12...@reventlessdev/reventless-in-memory@1.0.0-alpha.14) (2026-03-22)

### Bug Fixes

* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))
* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [1.0.0-alpha.13](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.12...@reventlessdev/reventless-in-memory@1.0.0-alpha.13) (2026-03-21)

### Bug Fixes

* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))
# [1.0.0-alpha.12](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.11...@reventlessdev/reventless-in-memory@1.0.0-alpha.12) (2026-03-20)

### Features

* **aws:** expose api/apiRole in Platform.T and remove unused MakeBundled modules ([a3be4cc](https://github.com/ReventlessDev/reventless-core/commit/a3be4cc5dc6041fb70c8e44a9e48f0a4f730242a))
# [1.0.0-alpha.11](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.10...@reventlessdev/reventless-in-memory@1.0.0-alpha.11) (2026-03-17)

### Bug Fixes

* **reventless-in-memory:** implement admin Activate/Deactivate mutations ([b36948f](https://github.com/ReventlessDev/reventless-core/commit/b36948fc18d272f79271f42f234de7e1460c916b))
### Features

* **reventless-aws:** implement per-plugin deployment with runtime schema stitching ([f16714c](https://github.com/ReventlessDev/reventless-core/commit/f16714c5d2b3ad869863ac30dc55ef3e1570bf4f))
# [1.0.0-alpha.10](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.9...@reventlessdev/reventless-in-memory@1.0.0-alpha.10) (2026-03-16)

* feat!: unify DCB and Aggregate command generation paths ([8c9bbad](https://github.com/ReventlessDev/reventless-core/commit/8c9bbad14082e7b696da35f5abb337520b1c8683))
* feat!: replace Core component with Platform_Admin, rename schema prefix Core_ → Admin_ ([940263d](https://github.com/ReventlessDev/reventless-core/commit/940263d8b39e28f4c874af3b0335ae81444928c4))
### Features

* differentiate ReadModel and StateViewSlice GraphQL query schemas ([62f6130](https://github.com/ReventlessDev/reventless-core/commit/62f6130d2ee34d65fe3eab1395d55c77c0309ddb))
* internalize scheduler, Core, and setup in Platform.makePlatform ([ce3e1b6](https://github.com/ReventlessDev/reventless-core/commit/ce3e1b60e8ffdbab1a6b5cd08d73f5e907726481))
* read version from package.json, make cloner opt-in, log platform version ([d8216a1](https://github.com/ReventlessDev/reventless-core/commit/d8216a1d569064ca14eff6e0c3be86923e5b84ad))

### BREAKING CHANGES

* DCB mutation return value changes from "ok" to a UUID.

* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.
# [1.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.8...@reventlessdev/reventless-in-memory@1.0.0-alpha.9) (2026-03-14)

### Bug Fixes

* eliminate Obj.magic from Platform DcbSpec boundaries ([135888b](https://github.com/ReventlessDev/reventless-core/commit/135888b226727d7ed8cc1e364e242b12071e107a))
### Features

* add optional DCB spec support to Core module and consolidate builder helpers ([06a5e6f](https://github.com/ReventlessDev/reventless-core/commit/06a5e6f2eeadbabd20fb7197318d760b91c34925))
* implement hybrid API/MCP schema split (core vs plugins) ([4f84866](https://github.com/ReventlessDev/reventless-core/commit/4f848667c0814533b2f3a294350c4310c61d9fc7))
# [1.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.7...@reventlessdev/reventless-in-memory@1.0.0-alpha.8) (2026-03-12)

### Features

* capitalize and prefix Core_ on GraphQL/MCP queries and mutations ([769420b](https://github.com/ReventlessDev/reventless-core/commit/769420b47ce35aba46d248d1529f7c72c7df9c0e))
* unify schema generation pipeline across GraphQL and MCP protocols ([84e05ae](https://github.com/ReventlessDev/reventless-core/commit/84e05aeca8c13000040d1230502b07350ab5daeb))
# [1.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.6...@reventlessdev/reventless-in-memory@1.0.0-alpha.7) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.4...@reventlessdev/reventless-in-memory@1.0.0-alpha.6) (2026-03-08)

### Bug Fixes

* add aggregate instance ID parameter to MCP and GraphQL mutations ([7a83ca4](https://github.com/ReventlessDev/reventless-core/commit/7a83ca4e3140d7e25e2bf0c75ac515bde864198f))
* **deps:** deduplicate graphql package to resolve schema conflict ([c33b030](https://github.com/ReventlessDev/reventless-core/commit/c33b030c14993e27700c5f0ec44a8a6ebe582468))
* **graphql:** register DCB mutation resolvers and fix schema timing ([3e7da8d](https://github.com/ReventlessDev/reventless-core/commit/3e7da8df7efb20a0ff3dc7c82e10a807cb516182))
* MCP server CORS and stateless transport handling ([38d1dad](https://github.com/ReventlessDev/reventless-core/commit/38d1dadc100d96787f3d4072dc3b1bc23fa6d492))
* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add AWS event history handlers and pagination for MCP resources ([33f6e39](https://github.com/ReventlessDev/reventless-core/commit/33f6e3910d50cfbe03c9d2d2ed2ea97b92ab7501))
* add effect-based handlers with Effect service injection at dispatch ([7ab3b3e](https://github.com/ReventlessDev/reventless-core/commit/7ab3b3e8a48890f2248b113328914755f604c07e))
* add MCP event history resources and fix QueryDb/MCP resource bugs ([3197d4f](https://github.com/ReventlessDev/reventless-core/commit/3197d4fb52a7b20bc68cd3088d9d6fac21a41f6f))
* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* auto-generate GraphQL mutations for InboundTranslationSlice ([7011fd2](https://github.com/ReventlessDev/reventless-core/commit/7011fd29f3029f001aa94fa78eb4f6b34d45451e))
* fix GraphQL SDL generation — correct naming, typed returns, and aggregate mutations ([ac93318](https://github.com/ReventlessDev/reventless-core/commit/ac933182dcd238b5f02ed98d1ddf03bb52b2c109))
* **graphql:** add GRAPHQL_DEBUG mode, schema inspector, and debugging guide ([61fcbee](https://github.com/ReventlessDev/reventless-core/commit/61fcbee6ee68337e95b5934a14279420e8ab8eca))
* harmonize error handling and retry with Effect across all AWS adapters ([a817bde](https://github.com/ReventlessDev/reventless-core/commit/a817bde2fbbda314ebdbc69aee17de717ee059ed))
* make Logger injectable at Platform level and replace Console.log in runtime builders ([5c5dd5b](https://github.com/ReventlessDev/reventless-core/commit/5c5dd5bc07c14c13a9fc5d857d26387e14d06dd6))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))
* replace explicit queryMode with automatic schema-driven DCB query construction ([8df4350](https://github.com/ReventlessDev/reventless-core/commit/8df4350c37f1f15678f4796f229647eaeb3e8222))
* replace timestamp-based sequenceNr with integer sequence numbers and optimistic locking ([50b7d3e](https://github.com/ReventlessDev/reventless-core/commit/50b7d3e9901daafc6dff8c9492a789bc700e9099))
# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.4...@reventlessdev/reventless-in-memory@1.0.0-alpha.5) (2026-03-08)

### Bug Fixes

* add aggregate instance ID parameter to MCP and GraphQL mutations ([7a83ca4](https://github.com/ReventlessDev/reventless-core/commit/7a83ca4e3140d7e25e2bf0c75ac515bde864198f))
* **deps:** deduplicate graphql package to resolve schema conflict ([c33b030](https://github.com/ReventlessDev/reventless-core/commit/c33b030c14993e27700c5f0ec44a8a6ebe582468))
* **graphql:** register DCB mutation resolvers and fix schema timing ([3e7da8d](https://github.com/ReventlessDev/reventless-core/commit/3e7da8df7efb20a0ff3dc7c82e10a807cb516182))
* MCP server CORS and stateless transport handling ([38d1dad](https://github.com/ReventlessDev/reventless-core/commit/38d1dadc100d96787f3d4072dc3b1bc23fa6d492))
* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add AWS event history handlers and pagination for MCP resources ([33f6e39](https://github.com/ReventlessDev/reventless-core/commit/33f6e3910d50cfbe03c9d2d2ed2ea97b92ab7501))
* add effect-based handlers with Effect service injection at dispatch ([7ab3b3e](https://github.com/ReventlessDev/reventless-core/commit/7ab3b3e8a48890f2248b113328914755f604c07e))
* add MCP event history resources and fix QueryDb/MCP resource bugs ([3197d4f](https://github.com/ReventlessDev/reventless-core/commit/3197d4fb52a7b20bc68cd3088d9d6fac21a41f6f))
* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* auto-generate GraphQL mutations for InboundTranslationSlice ([7011fd2](https://github.com/ReventlessDev/reventless-core/commit/7011fd29f3029f001aa94fa78eb4f6b34d45451e))
* fix GraphQL SDL generation — correct naming, typed returns, and aggregate mutations ([ac93318](https://github.com/ReventlessDev/reventless-core/commit/ac933182dcd238b5f02ed98d1ddf03bb52b2c109))
* **graphql:** add GRAPHQL_DEBUG mode, schema inspector, and debugging guide ([61fcbee](https://github.com/ReventlessDev/reventless-core/commit/61fcbee6ee68337e95b5934a14279420e8ab8eca))
* harmonize error handling and retry with Effect across all AWS adapters ([a817bde](https://github.com/ReventlessDev/reventless-core/commit/a817bde2fbbda314ebdbc69aee17de717ee059ed))
* make Logger injectable at Platform level and replace Console.log in runtime builders ([5c5dd5b](https://github.com/ReventlessDev/reventless-core/commit/5c5dd5bc07c14c13a9fc5d857d26387e14d06dd6))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))
# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.3...@reventlessdev/reventless-in-memory@1.0.0-alpha.4) (2026-03-03)

### Features

* **api:** implement Api component with GraphQL fragment generation and schema stitching ([c882d3a](https://github.com/ReventlessDev/reventless-core/commit/c882d3aae8722cf6cbe9b4fbf9518d9f434ce06a))
* **platform:** expose Plugin, Core, makeScheduler, makePlatform via Platform.T ([0df4bf3](https://github.com/ReventlessDev/reventless-core/commit/0df4bf333ea4f9c0e51e96df1ad0da4ab471ffe8))
# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.2...@reventlessdev/reventless-in-memory@1.0.0-alpha.3) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory

# 1.0.0-alpha.2 (2026-03-01)

### Bug Fixes

* **in-memory:** replace deprecated String.sliceToEnd with String.slice ([a9dfd00](https://github.com/ReventlessDev/reventless-core/commit/a9dfd00df1bff66adcd56a4b804b47d634b823c1))
* **reventless-in-memory:** expand AsyncTest include to avoid external [@send](https://github.com/send) binding errors ([a9f7b55](https://github.com/ReventlessDev/reventless-core/commit/a9f7b553226f23c7700c54ae00fc92ed315b1098))
* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))
* feat(reventless-core)!: rename package from @reventlessdev/reventless to @reventlessdev/reventless-core ([5e93146](https://github.com/ReventlessDev/reventless-core/commit/5e9314692b5b5d60beee187564ba94bc9fd46c05))
### Features

* **in-memory:** implement P0 GraphQL server for mutations and queries ([2627cdc](https://github.com/ReventlessDev/reventless-core/commit/2627cdc147b2deeb160e9642750bf26da8f95108))
* **in-memory:** implement P1/P2 gaps — QueryEngine, Counter, Scheduler ([faa2d52](https://github.com/ReventlessDev/reventless-core/commit/faa2d52e205f81d3c0d8a203a5b69dcaa19cf218))
* **in-memory:** implement P3 gap — HeartbeatRunner_InMemory ([9f188b5](https://github.com/ReventlessDev/reventless-core/commit/9f188b53d23eae1a768f96291ad75435a828b309))
* **rescript-effect:** Effect library bindings + stream-based framework handlers ([#30](https://github.com/ReventlessDev/reventless-core/issues/30)) ([f2ca5cf](https://github.com/ReventlessDev/reventless-core/commit/f2ca5cf3d56d66a9f4ab56b543d7bf82e48448dd))

### BREAKING CHANGES

* ReventlessSpec namespace renamed to Reventless; the reventless-core
package namespace renamed from Reventless to ReventlessCore.
All usages of ReventlessSpec.* must be updated to Reventless.*;
all usages of Reventless.* (core) in dependent packages must be updated to ReventlessCore.*

* package renamed for consistency with sibling packages
and the repository name. ReScript namespace "Reventless" is unchanged —
no source code updates required.

- git mv reventless/reventless → reventless/reventless-core
- package.json and rescript.json name updated to @reventlessdev/reventless-core
- reventless-aws and reventless-in-memory dependency references updated
- Root package.json and rescript.json renamed to "reventless-monorepo" to
  avoid name collision that caused ReScript to skip building the sub-package
- Updated recompiled .res.mjs output files with new relative import paths
