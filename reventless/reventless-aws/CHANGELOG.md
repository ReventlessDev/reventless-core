# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 3.0.0-alpha.42 (2026-04-09)

### Bug Fixes

* **AppSync:** use deploySchemaWithRetry in updateSchema ([3f741f7](https://github.com/ReventlessDev/reventless-core/commit/3f741f7eb435264f3b7d4ed61aa8f15eb965044f))
### Features

* **AppSync:** add deploySchemaWithRetry for concurrent schema modification handling ([f58f920](https://github.com/ReventlessDev/reventless-core/commit/f58f920af1a396aa71df6d2fe3f57351d3792190))
* **reventless-aws:** add Util_AppSync_Caller for IAM-signed AppSync dispatch ([8c0bc23](https://github.com/ReventlessDev/reventless-core/commit/8c0bc232f215b22c2bee8eac8d36f991ef18d430))


# 3.0.0-alpha.41 (2026-04-07)

### Bug Fixes

* **query-db:** use idField name for DynamoDB attribute definition in GSI ([bd2ab7d](https://github.com/ReventlessDev/reventless-core/commit/bd2ab7db101c6a3e5f89ef268503c90f38d1a453))


# 3.0.0-alpha.40 (2026-04-07)

### Features

* **ppx+querydb:** annotation-driven key design and sort key queries ([dee6de8](https://github.com/ReventlessDev/reventless-core/commit/dee6de84c2d2de5431d064f18ac7132bc8c23110))


# 3.0.0-alpha.39 (2026-04-07)

### Dependency Updates

* **@reventlessdev/reventless-core** updated to `^3.0.0-alpha.39`
* **@reventlessdev/reventless-infra** updated to `^3.0.0-alpha.26`
* **@reventlessdev/reventless-spec** updated to `^3.0.0-alpha.21`


# 3.0.0-alpha.38 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))
* **aws:** guard verifyTtl against undefined ttl from Pulumi ([e149204](https://github.com/ReventlessDev/reventless-core/commit/e1492042c9044e40662b643dd2713a3d389a90da))
* **aws:** inject partition key id into DynamoDB items before put ([aa51fb5](https://github.com/ReventlessDev/reventless-core/commit/aa51fb52dff1aff7845c3670394f61eb52c93d80))
* **aws:** safe claims access and GSI IAM permission for AppSync/Lambda ([f0d8324](https://github.com/ReventlessDev/reventless-core/commit/f0d8324693924314a90ad7c79d0837a923fc3197))


# 3.0.0-alpha.37 (2026-04-06)

### Bug Fixes

* DCB runtime — empty tags fallback, tag_composite GSI, stream meta ([4c3a6ad](https://github.com/ReventlessDev/reventless-core/commit/4c3a6ad9f0e1a9fa357a7230d7151ba34a0c116b))
* wire DCB EventCollector and StateViewSlice Lambda pipeline ([846228f](https://github.com/ReventlessDev/reventless-core/commit/846228fc9193a4c344399ecae924241e7944204f))
### Features

* implement [@composite](https://github.com/composite)PartitionTag PPX annotation for multi-field DCB partition keys ([cf26b15](https://github.com/ReventlessDev/reventless-core/commit/cf26b15f639d151451c9aa04d32603ef9d5df315))


# 3.0.0-alpha.36 (2026-04-05)

### Bug Fixes

* DCB runtime — empty tags fallback, tag_composite GSI, stream meta ([4c3a6ad](https://github.com/ReventlessDev/reventless-core/commit/4c3a6ad9f0e1a9fa357a7230d7151ba34a0c116b))
* wire DCB EventCollector and StateViewSlice Lambda pipeline ([846228f](https://github.com/ReventlessDev/reventless-core/commit/846228fc9193a4c344399ecae924241e7944204f))


# 3.0.0-alpha.35 (2026-04-05)

### Bug Fixes

* DCB command pipeline runtime fixes ([9646c97](https://github.com/ReventlessDev/reventless-core/commit/9646c97e7fd86f28d5035d77ff40af66f592e61e))


# 3.0.0-alpha.34 (2026-04-04)

* feat!: add reventless-ppx with @@reventless.spec, @@reventless.behavior, @@reventless.dcbTags ([cb203ec](https://github.com/ReventlessDev/reventless-core/commit/cb203ece5ea3a1b92ba7d1a57d9e12bb6c4c2487))
* feat!: Extension Blueprint pattern with auto-merge and plugin naming ([0856d4d](https://github.com/ReventlessDev/reventless-core/commit/0856d4d2a23b8d5175fd091f90110d4c44927191))
### Features

* add Relay server compliance to GraphQL API ([bd9245d](https://github.com/ReventlessDev/reventless-core/commit/bd9245da87023247643c5fa37cee21b0cde0f61e))
* make Relay connection spec the default for all list queries ([fa8d258](https://github.com/ReventlessDev/reventless-core/commit/fa8d258ddeb30bf02f97b1c1f3cc564e15632e94))

### BREAKING CHANGES

* Example spec files no longer export manual moduleUrl/name/Id
declarations — these are now PPX-generated. Downstream code referencing these
exports is unaffected (same values, different source).
* Platform.Extension.Make returns Extension.Blueprint
instead of Extension.T. Plugin.make ~extensions param type changes
accordingly. Make2/Make3/MakeMulti removed from Platform.T.



# 3.0.0-alpha.33 (2026-04-03)

### Bug Fixes

* resolve pluginRmTableName export and StackReference decoding in Platform ([de8a337](https://github.com/ReventlessDev/reventless-core/commit/de8a337551e6e0f2edad1daa97082e5cc61504c8))
### Features

* migrate AppSync resolvers from VTL to APPSYNC_JS runtime ([22f8c15](https://github.com/ReventlessDev/reventless-core/commit/22f8c15cee7d99859a56e5a6fbc11f9e9ff566c9))


# 3.0.0-alpha.32 (2026-04-02)

### Features

* add tags field to resource and resolvedResource records ([18911e6](https://github.com/ReventlessDev/reventless-core/commit/18911e66aa94e60d4a9b72ba1d1ca84dd3fb1a9f))


# 3.0.0-alpha.31 (2026-04-02)

* feat!: add deploy lifecycle hooks, enrich resource metadata, and add Adapter.make factory ([0a171f4](https://github.com/ReventlessDev/reventless-core/commit/0a171f4b8aec0ee47fd7ee5069adf5d5b194548e))

### BREAKING CHANGES

* Adapter.resource.info replaced with resourceInfo variant type.
Service field values now prefixed with provider namespace (e.g. "aws:DynamoDb").
New required fields on resource/resolvedResource: role, region, resourceType, configuration.



# 3.0.0-alpha.30 (2026-04-02)

### Features

* **aws:** add generic env var and IAM extension point for all Lambdas ([0335fe5](https://github.com/ReventlessDev/reventless-core/commit/0335fe56a0a992ddb7fed0cb768e053bfa9945df))


# 3.0.0-alpha.29 (2026-03-31)

### Bug Fixes

* migrate remaining Console.log calls to unified Logger/EffectLogger ([0216b0d](https://github.com/ReventlessDev/reventless-core/commit/0216b0dde5597b2bc539a960ac86a18071777815))
### Features

* return Plugin.outputs from deployPlugin ([22e59f7](https://github.com/ReventlessDev/reventless-core/commit/22e59f730c5c87dd0e3e8d4cf225d401298759f8))


# 3.0.0-alpha.28 (2026-03-30)

### Features

* add event publish hooks and AWS query interceptor support ([5c4ec59](https://github.com/ReventlessDev/reventless-core/commit/5c4ec598f6cc7115255b4b18c9decf8007630f15))


# [3.0.0-alpha.27](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.26...@reventlessdev/reventless-aws@3.0.0-alpha.27) (2026-03-30)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# [3.0.0-alpha.26](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.25...@reventlessdev/reventless-aws@3.0.0-alpha.26) (2026-03-29)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# [3.0.0-alpha.25](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.23...@reventlessdev/reventless-aws@3.0.0-alpha.25) (2026-03-28)

* refactor!: migrate Lambda entry points from ReScript to plain ESM ([2c1ea8f](https://github.com/ReventlessDev/reventless-core/commit/2c1ea8f1601e2142690b11f8bb0ffc2fd45c7f51))
* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))
### Features

* add identity propagation and interceptor hook to CommandGenerator pipeline ([37494a5](https://github.com/ReventlessDev/reventless-core/commit/37494a50fe70f8db7d6d35fd733a4fc75eade5bc))

### BREAKING CHANGES

* Lambda Layer entry point paths changed from
*EntryPoint.res.mjs to *EntryPoint.mjs — requires layer rebuild.
* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [3.0.0-alpha.24](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.23...@reventlessdev/reventless-aws@3.0.0-alpha.24) (2026-03-27)

* refactor!: migrate Lambda entry points from ReScript to plain ESM ([2c1ea8f](https://github.com/ReventlessDev/reventless-core/commit/2c1ea8f1601e2142690b11f8bb0ffc2fd45c7f51))
* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))

### BREAKING CHANGES

* Lambda Layer entry point paths changed from
*EntryPoint.res.mjs to *EntryPoint.mjs — requires layer rebuild.
* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [3.0.0-alpha.23](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.20...@reventlessdev/reventless-aws@3.0.0-alpha.23) (2026-03-27)

### Bug Fixes

* conditionally exclude ID parameter from StateViewSlice GraphQL queries ([43de4b6](https://github.com/ReventlessDev/reventless-core/commit/43de4b667d89235ea03b3e1584070515e10e71de))
* **reventless-aws:** unwrap topicItem in DCB entry point SQS command routing ([0834056](https://github.com/ReventlessDev/reventless-core/commit/083405640d928503e8a56d5d8c7b326ad86d1313))
* feat!: remove resolverConfig from Behavior module type ([6f54015](https://github.com/ReventlessDev/reventless-core/commit/6f54015e3abc1c5c05472c8f54645723a0f5ed28))
* feat!: decouple DCB slices from shared event log union type ([2a40e8d](https://github.com/ReventlessDev/reventless-core/commit/2a40e8dd9babfb88440fcaccde6fb667b60e0ba9))

### BREAKING CHANGES

* Behavior.T no longer requires resolverConfig. Remove it
from all Behavior implementations.
* All DCB slice specs must use `producedEvent`/`consumedEvent`
instead of `module DcbEventLogSpec`. Plugin `DcbSpec` no longer has `type event`
or `with type dcbEvent` constraints.



# [3.0.0-alpha.22](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.20...@reventlessdev/reventless-aws@3.0.0-alpha.22) (2026-03-26)

### Bug Fixes

* conditionally exclude ID parameter from StateViewSlice GraphQL queries ([43de4b6](https://github.com/ReventlessDev/reventless-core/commit/43de4b667d89235ea03b3e1584070515e10e71de))
* **reventless-aws:** unwrap topicItem in DCB entry point SQS command routing ([0834056](https://github.com/ReventlessDev/reventless-core/commit/083405640d928503e8a56d5d8c7b326ad86d1313))


# [3.0.0-alpha.21](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.20...@reventlessdev/reventless-aws@3.0.0-alpha.21) (2026-03-26)

### Bug Fixes

* conditionally exclude ID parameter from StateViewSlice GraphQL queries ([43de4b6](https://github.com/ReventlessDev/reventless-core/commit/43de4b667d89235ea03b3e1584070515e10e71de))
* **reventless-aws:** unwrap topicItem in DCB entry point SQS command routing ([0834056](https://github.com/ReventlessDev/reventless-core/commit/083405640d928503e8a56d5d8c7b326ad86d1313))


# [3.0.0-alpha.20](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.19...@reventlessdev/reventless-aws@3.0.0-alpha.20) (2026-03-23)

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
# [3.0.0-alpha.19](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.17...@reventlessdev/reventless-aws@3.0.0-alpha.19) (2026-03-22)

### Bug Fixes

* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))
* **reventless-aws:** use deep effect imports in hand-written handler factories ([7f42d25](https://github.com/ReventlessDev/reventless-core/commit/7f42d25884ddab90fa3e4217ba9ca7db7a664eb3))
* **reventless-aws:** use namespace imports for effect deep paths ([11bedcf](https://github.com/ReventlessDev/reventless-core/commit/11bedcf48400e1be47deac6234680d2959c0b7e1))
* **reventless-aws:** use package specifiers for layer-provided modules ([7fdf04b](https://github.com/ReventlessDev/reventless-core/commit/7fdf04b6757a7006d3e425c881212c15a932f469))
* **reventless-layer-builder:** include [@smithy](https://github.com/smithy) in layer for ESM resolution ([ff7f4ab](https://github.com/ReventlessDev/reventless-core/commit/ff7f4ab4cbcd2fdd203432a48603ee766b662b9e))
* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [3.0.0-alpha.18](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.17...@reventlessdev/reventless-aws@3.0.0-alpha.18) (2026-03-21)

### Bug Fixes

* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))
* **reventless-aws:** use deep effect imports in hand-written handler factories ([7f42d25](https://github.com/ReventlessDev/reventless-core/commit/7f42d25884ddab90fa3e4217ba9ca7db7a664eb3))
* **reventless-aws:** use package specifiers for layer-provided modules ([7fdf04b](https://github.com/ReventlessDev/reventless-core/commit/7fdf04b6757a7006d3e425c881212c15a932f469))
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

* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.
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

* package renamed for consistency with sibling packages
and the repository name. ReScript namespace "Reventless" is unchanged —
no source code updates required.

- git mv reventless/reventless → reventless/reventless-core
- package.json and rescript.json name updated to @reventlessdev/reventless-core
- reventless-aws and reventless-in-memory dependency references updated
- Root package.json and rescript.json renamed to "reventless-monorepo" to
  avoid name collision that caused ReScript to skip building the sub-package
- Updated recompiled .res.mjs output files with new relative import paths
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
