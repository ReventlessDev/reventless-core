# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.75 (2026-08-08)

### Features

* **core:** add a runtime hook for command outcomes ([f2092a8](https://github.com/ReventlessDev/reventless-core/commit/f2092a8f9a8d8d7feee4f3de19bea7297a250cbd))


# 1.0.0-alpha.74 (2026-08-08)

### Features

* **core,aws,local:** add the RuntimeExtension cold-start seam ([143e30e](https://github.com/ReventlessDev/reventless-core/commit/143e30eeded6232ce7f0fcc18328939b2917bb31))


# 1.0.0-alpha.73 (2026-08-05)

### Features

* **local,aws:** carry the changed row in the live-update descriptor ([9272e2e](https://github.com/ReventlessDev/reventless-core/commit/9272e2e18e9e1d740f9a2c5aa83eccbcb41feff7))


# 1.0.0-alpha.72 (2026-08-03)

### Features

* **aws:** let a deployment hand its plugins a geocoder ([143bf41](https://github.com/ReventlessDev/reventless-core/commit/143bf4137765362ce07dd42db0f4a57057da9f13))
* **platform:** let a deployment choose what the host shell does ([ae0aec3](https://github.com/ReventlessDev/reventless-core/commit/ae0aec33dcf641f02187e8d6a3f3594c506820b6))


# 1.0.0-alpha.71 (2026-08-02)

### Features

* **ppx:** add [@offload](https://github.com/offload) field shorthand with per-field threshold ([3d5e3b5](https://github.com/ReventlessDev/reventless-core/commit/3d5e3b5da5010547ce0eaf7d94d660daec67feed))


# 1.0.0-alpha.70 (2026-08-02)

### Features

* **aws,core,doc:** environment-tiered CloudWatch log retention and levels ([8032023](https://github.com/ReventlessDev/reventless-core/commit/803202305a7d352484b8df5e58df03c92ca58b5f))


# 1.0.0-alpha.69 (2026-08-01)

**Note:** Version bump only for package doc





# 1.0.0-alpha.68 (2026-07-31)

* feat(rescript)!: one Node bindings package, not two ([1258d8c](https://github.com/ReventlessDev/reventless-core/commit/1258d8c2b2ff2636b36a849fc5bdf9005c6fb0eb))

### BREAKING CHANGES

* `@reventlessdev/rescript-node-streams` and
`@reventlessdev/rescript-node-zlib` are replaced by
`@reventlessdev/rescript-node`. Module names are unchanged.



# 1.0.0-alpha.67 (2026-07-28)

### Features

* **rescript-web:** web-globals bindings + E2E verifier for client publish ([c3613fd](https://github.com/ReventlessDev/reventless-core/commit/c3613fd7ef75b18f1c6bfb2c7905a6d493eec6f2))


# 1.0.0-alpha.66 (2026-07-27)

### Features

* **seed:** guarded AWS store reset (seed:reset) with per-project scope selection ([8446172](https://github.com/ReventlessDev/reventless-core/commit/8446172cbb53776a58f53220d19e96d96ce94508))


# 1.0.0-alpha.65 (2026-07-26)

### Features

* **seed:** per-provider seed scripts, shared machinery, exportable data sets ([ba43e9e](https://github.com/ReventlessDev/reventless-core/commit/ba43e9efab84dd2955b6dafd1e187fd4aad699ad))


# 1.0.0-alpha.64 (2026-07-26)

* feat(examples)!: gate hybrid auto-shipping on a shipping method ([d620e12](https://github.com/ReventlessDev/reventless-core/commit/d620e1292db1b470670654588d04cc51b34d2ab9))
### Features

* **seed:** add a reusable GraphQL seeding harness ([e8c2230](https://github.com/ReventlessDev/reventless-core/commit/e8c2230f25d59e7f93518bff2b2a55997395fb2c))

### BREAKING CHANGES

* PlaceOrder and OrderPlaced gain a required shippingMethod
field; the RefundOrder slice and its IssueRefund command are removed.



# 1.0.0-alpha.63 (2026-07-22)

### Bug Fixes

* **aws:** keep an empty DCB tag value from breaking the append ([1c0ab40](https://github.com/ReventlessDev/reventless-core/commit/1c0ab40f25b596702a81f42686d77c5e423e9b44))


# 1.0.0-alpha.62 (2026-07-22)

* refactor!: retire the stale "core" vocabulary for platform things ([34e7480](https://github.com/ReventlessDev/reventless-core/commit/34e7480992bd58906a250b0a1ce6ff2c5ba45260))

### BREAKING CHANGES

* the built-in extension point is renamed Core.Plugin ->
Platform.Plugin. This replaces the CorePluginExtPointCmdTopic SQS queue
with PlatformPluginExtPointCmdTopic (a replacement, not an update) and
breaks every already-deployed plugin's connection until redeployed.
Wipe the alpha stack and redeploy fresh rather than migrating.

Build clean; 1349 tests green (interop 50, core 518, local 501, aws 280).



# 1.0.0-alpha.61 (2026-07-17)

**Note:** Version bump only for package doc





# 1.0.0-alpha.60 (2026-07-16)

**Note:** Version bump only for package doc





# 1.0.0-alpha.59 (2026-07-11)

**Note:** Version bump only for package doc





# 1.0.0-alpha.58 (2026-07-10)

**Note:** Version bump only for package doc





# 1.0.0-alpha.57 (2026-07-07)

### Bug Fixes

* **reventless-aws:** fence composite-partition DCB slices on one composite key ([e5f2d95](https://github.com/ReventlessDev/reventless-core/commit/e5f2d95652d795e4dea60e28548f96100a997e78))


# 1.0.0-alpha.56 (2026-07-06)

**Note:** Version bump only for package doc





# 1.0.0-alpha.55 (2026-07-04)

### Features

* **examples,docs:** enable aggregate snapshots on the Product example + document the feature (aggregate-snapshotting plan, steps 6-7, COMPLETE) ([fdda793](https://github.com/ReventlessDev/reventless-core/commit/fdda793e7bba0cd7482b4ba3ac1c73572f75a3c0))


# 1.0.0-alpha.54 (2026-06-29)

### Bug Fixes

* **docs:** derive D2 image linkPath from baseUrl so diagrams resolve per version ([ec24e9f](https://github.com/ReventlessDev/reventless-core/commit/ec24e9f0cba04dca04ea269dbdc7edde5b625b0a))


# 1.0.0-alpha.53 (2026-06-27)

### Bug Fixes

* **docs:** convert lone Mermaid diagram to D2 in appsync-events-live-updates ([317381a](https://github.com/ReventlessDev/reventless-core/commit/317381a64bc44629eb09a6eab44207b88bb6620b))
### Features

* **doc:** adopt V16e brand logo, self-host Geist webfont ([a56b319](https://github.com/ReventlessDev/reventless-core/commit/a56b319eac58dc4feafa0731c08063ef2dada8f5))
* verify category exists in AddProduct via cross-partition DCB read ([074d4fa](https://github.com/ReventlessDev/reventless-core/commit/074d4faecf694164f2e0c789c4d94cae402b03e1))


# 1.0.0-alpha.52 (2026-06-23)

### Bug Fixes

* **dcb:** scope DynamoDB consistency fences per event type ([a20646f](https://github.com/ReventlessDev/reventless-core/commit/a20646f31a33041871f123cf66e65dd8dff429c3))


# 1.0.0-alpha.51 (2026-06-22)

**Note:** Version bump only for package doc





# 1.0.0-alpha.50 (2026-06-21)

### Features

* **dcb:** cross-partition secondary-tag reads (Phase 7) ([9e1f8b3](https://github.com/ReventlessDev/reventless-core/commit/9e1f8b3595004b92148dd053aae380078baa42a3))


# 1.0.0-alpha.49 (2026-06-20)

### Features

* **dcb:** narrow query clauses to types that can carry each tag (Issue 14) ([6bceae6](https://github.com/ReventlessDev/reventless-core/commit/6bceae675b91154b5a1abf73a6aaca56533cbbe8))


# 1.0.0-alpha.48 (2026-06-18)

**Note:** Version bump only for package doc





# 1.0.0-alpha.47 (2026-06-18)

**Note:** Version bump only for package doc





# 1.0.0-alpha.46 (2026-06-18)

**Note:** Version bump only for package doc





# 1.0.0-alpha.45 (2026-06-18)

### Features

* **aws:** deploy-time synthetic heartbeat for zero-downtime plugin handover ([347b14f](https://github.com/ReventlessDev/reventless-core/commit/347b14fc702f5ddb690ee9624519abf36d9a93b8))


# 1.0.0-alpha.44 (2026-06-17)

* feat(example)!: type the directive channel in the hybrid example ([7ee7527](https://github.com/ReventlessDev/reventless-core/commit/7ee75275a01808c83df3e5c4f309c1be851bcffb))
* feat!: harmonize plugin make() across aggregate/DCB/hybrid; AutoUI default-on ([6f3b95e](https://github.com/ReventlessDev/reventless-core/commit/6f3b95e6aa8a136c6e837346c41a3a4dff0f9405))

### BREAKING CHANGES

* `Products_ExtensionPoint.directive` and
`Orders_ExtensionPoint.directive` are no longer `unit`. Out-of-tree
consumers that declared `type directive = unit` and then referenced it
in code need a one-line rename. In-repo callers are updated.
* makeAutoUIManifest signature dropped ~aggregates and
~readModels; replaced with ~pluginStructure. Hand-written Plugin.res files
that pass ~uiBundleUrl to plugin.make must drop the arg and rely on the
generator-emitted env var read.



# 1.0.0-alpha.43 (2026-06-12)

**Note:** Version bump only for package doc





# 1.0.0-alpha.42 (2026-06-10)

### Bug Fixes

* **aws:** repair StateTopic channel format so admin Plugins list live-updates ([de444b7](https://github.com/ReventlessDev/reventless-core/commit/de444b7d5a9cf6192a6880109ab77de12c07191c))
* refactor(reventless-local)!: rename reventless-in-memory to reventless-local ([f36e17c](https://github.com/ReventlessDev/reventless-core/commit/f36e17c407714ab9740393fac96865d6a5c143c9))
### Features

* **reventless-vscode:** component/test explorer surfaces + watch controls ([b229e69](https://github.com/ReventlessDev/reventless-core/commit/b229e69fb69f9346b7d5420b08c4ccbbaa207f8a))

### BREAKING CHANGES

* @reventlessdev/reventless-in-memory -> @reventlessdev/reventless-local;
namespace ReventlessInMemory -> ReventlessLocal.



# 1.0.0-alpha.41 (2026-06-09)

**Note:** Version bump only for package doc





# 1.0.0-alpha.40 (2026-06-08)

**Note:** Version bump only for package doc





# 1.0.0-alpha.39 (2026-06-07)

**Note:** Version bump only for package doc





# 1.0.0-alpha.38 (2026-06-06)

* refactor(reventless-local)!: rename reventless-in-memory to reventless-local ([966855f](https://github.com/ReventlessDev/reventless-core/commit/966855fd31e518d56a381bf40204735809cead15))
### Features

* **reventless-vscode:** component/test explorer surfaces + watch controls ([ec9aefa](https://github.com/ReventlessDev/reventless-core/commit/ec9aefa63a5da64952a0bb2b1e8312a454e3efa8))

### BREAKING CHANGES

* @reventlessdev/reventless-in-memory -> @reventlessdev/reventless-local;
namespace ReventlessInMemory -> ReventlessLocal.



# 1.0.0-alpha.37 (2026-06-04)

### Bug Fixes

* **aws:** repair StateTopic channel format so admin Plugins list live-updates ([7aaa563](https://github.com/ReventlessDev/reventless-core/commit/7aaa563246c647a913da440bd382c20c953231ab))


# 1.0.0-alpha.36 (2026-05-25)

**Note:** Version bump only for package doc





# 1.0.0-alpha.35 (2026-05-25)

### Bug Fixes

* **docs:** make the navbar responsive ([c2c7215](https://github.com/ReventlessDev/reventless-core/commit/c2c7215c0390a5a39da1a13a96ac3be828fbf645))
* **docs:** published-version-aware version selector + working search ([547cae7](https://github.com/ReventlessDev/reventless-core/commit/547cae7a9acd9fb06b23d950c386b74e7afbd0b9))
### Features

* **site:** brand logo (Variant 2a icon + wordmark) with responsive navbar ([720262e](https://github.com/ReventlessDev/reventless-core/commit/720262e02a47a4bf7a30c96046624fa704579add)), closes [#1a1a2](https://github.com/ReventlessDev/reventless-core/issues/1a1a2) [#e8e8f0](https://github.com/ReventlessDev/reventless-core/issues/e8e8f0)


# 1.0.0-alpha.34 (2026-05-19)

* refactor(aws)!: rename DCB Lambdas to <Plugin>StateChanges[Async] ([f2b20ca](https://github.com/ReventlessDev/reventless-core/commit/f2b20ca86c66cfd88d87696d89b745d70c5f156b))
### Features

* @[@reventless](https://github.com/reventless).async opt-in; sync command dispatch as default ([85885c8](https://github.com/ReventlessDev/reventless-core/commit/85885c80a70cfcbf4e1ac068c7115e6b6cfa8400))
* **platform:** commandHandlerConfig for per-flavor Lambda tuning ([4154061](https://github.com/ReventlessDev/reventless-core/commit/4154061d9343f90ce61955992d9119d0f7a251e1))

### BREAKING CHANGES

* this is a Pulumi resource rename without `aliases`,
so `pulumi up` will destroy and recreate the DCB Lambda, its SQS
queue(s), the AppSync DataSource and resolvers, and associated IAM.
In-flight FIFO messages on async StateChangeSlices are lost. Plan a
maintenance window for stacks with sustained async DCB traffic.



# 1.0.0-alpha.33 (2026-05-16)

### Features

* **ppx:** add @[@reventless](https://github.com/reventless).visibility to hide components from AutoUI ([bd302cf](https://github.com/ReventlessDev/reventless-core/commit/bd302cfc5bd5d4dfe50c8e1bf8596ab67e36c74e))


# 1.0.0-alpha.32 (2026-05-14)

**Note:** Version bump only for package doc





# 1.0.0-alpha.31 (2026-05-13)

* feat(spec)!: standardise event/command envelope (StoredEvent, optional meta, position, persisted DCB meta, causation) ([7ef3176](https://github.com/ReventlessDev/reventless-core/commit/7ef3176c6330810c817f43a52b881b5a0efee30e))

### BREAKING CHANGES

* meta.ip / meta.user go from required `string` to optional
record fields (`?: string`). Code that did `meta.user == "unknown"` to
detect system messages must check for field absence. Storage tables built
before this change are not migrated (greenfield — recreate the EventLog /
DcbEventLog tables; DynamoDB range key renamed from `seq` to `position`,
SQLite dcb_event gains meta and recorded_at columns).



# 1.0.0-alpha.30 (2026-05-10)

### Bug Fixes

* **aggregate:** atomic multi-event append via TransactWriteItems ([ef077f4](https://github.com/ReventlessDev/reventless-core/commit/ef077f4ddf7f5467d12ac8a8de4723016632db7c))
* **aggregate:** cap appendWithCondition at 100 events up front ([7079401](https://github.com/ReventlessDev/reventless-core/commit/70794017b47272ffaae4242d476e7c2406d334e9))
* **aggregate:** propagate decide-errors as Rejected outcomes ([7eb1d59](https://github.com/ReventlessDev/reventless-core/commit/7eb1d599dd7d02791bffa915c19c40479ce6e9da))


# 1.0.0-alpha.29 (2026-05-05)

### Features

* **extension:** add PublishStateChangeSliceCommand for slice delegates ([0500b79](https://github.com/ReventlessDev/reventless-core/commit/0500b79d80632611e52ff0565e3e04472330a51e))


# 1.0.0-alpha.28 (2026-05-03)

* feat(ppx,codegen)!: retire @reventless.projections; add spec-stem-uniqueness lint ([a6fa11f](https://github.com/ReventlessDev/reventless-core/commit/a6fa11fa26086fd356e16b01b6f15b819630534e))

### BREAKING CHANGES

* any user code applying @reventless.projections to
an inline wrapper module inside Plugin.res fails to compile with a
clear migration message. Move the per-source Mapping.Make modules
and the let mappings array into the slice-local
<Plural>_Projections.res file (in ReadModel/) and add
@@reventless.mappings at the top. Auto-generated Plugin.res then
references the projections module directly.



# 1.0.0-alpha.27 (2026-04-26)

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



# 1.0.0-alpha.26 (2026-04-18)

**Note:** Version bump only for package doc





# 1.0.0-alpha.25 (2026-04-12)

### Features

* **commands:** end-to-end CommandResult — synchronous business-rule errors reach the GraphQL client ([c241d74](https://github.com/ReventlessDev/reventless-core/commit/c241d7418205799bdc79472ebbd04f40b392f870))
* **commands:** extend CommandAccepted with entityId and eventCount ([747b85d](https://github.com/ReventlessDev/reventless-core/commit/747b85dc50042124f360627c5489321eea0d26e4))
* **platform:** MakeAsync opt-in for aggregates and DCB slices ([6970d88](https://github.com/ReventlessDev/reventless-core/commit/6970d889fa05e738dbda5d8e450a1dcf927b23b7))


# 1.0.0-alpha.24 (2026-04-09)

### Features

* **ppx:** implement [@no](https://github.com/no)Api to exclude commands from GraphQL/MCP exposure ([079b686](https://github.com/ReventlessDev/reventless-core/commit/079b68693976a53f8094f1233ebf8b67a86a65c0))


# 1.0.0-alpha.23 (2026-04-07)

### Features

* **ppx+querydb:** annotation-driven key design and sort key queries ([dee6de8](https://github.com/ReventlessDev/reventless-core/commit/dee6de84c2d2de5431d064f18ac7132bc8c23110))
* **ppx:** auto-inject open Reventless.Projection for StateViewSlice files ([ad15b25](https://github.com/ReventlessDev/reventless-core/commit/ad15b253f2645ff2fa790d557734c3ccacb33936))


# 1.0.0-alpha.22 (2026-04-06)

**Note:** Version bump only for package doc





# 1.0.0-alpha.21 (2026-04-06)

**Note:** Version bump only for package doc





# 1.0.0-alpha.20 (2026-04-05)

**Note:** Version bump only for package doc





# 1.0.0-alpha.19 (2026-04-04)

### Features

* reventless-ppx — [@partition](https://github.com/partition)Tag, [@no](https://github.com/no)Tag, [@dcb](https://github.com/dcb)Tag field annotations ([64646b8](https://github.com/ReventlessDev/reventless-core/commit/64646b8813ba8c55febb3383bc40a78c5b09147e))


# 1.0.0-alpha.18 (2026-03-31)

### Features

* add reventless-skills AI plugin with 7 skills, 3 commands, 2 agents ([46f6534](https://github.com/ReventlessDev/reventless-core/commit/46f6534fa031bcc24696c365e450e8d11fa1a366))


# [1.0.0-alpha.17](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.15...doc@1.0.0-alpha.17) (2026-03-28)

**Note:** Version bump only for package doc





# [1.0.0-alpha.16](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.15...doc@1.0.0-alpha.16) (2026-03-27)

**Note:** Version bump only for package doc





# [1.0.0-alpha.15](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.12...doc@1.0.0-alpha.15) (2026-03-27)

* feat!: remove resolverConfig from Behavior module type ([6f54015](https://github.com/ReventlessDev/reventless-core/commit/6f54015e3abc1c5c05472c8f54645723a0f5ed28))
* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* Behavior.T no longer requires resolverConfig. Remove it
from all Behavior implementations.
* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [1.0.0-alpha.14](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.12...doc@1.0.0-alpha.14) (2026-03-26)

* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [1.0.0-alpha.13](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.12...doc@1.0.0-alpha.13) (2026-03-26)

* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [1.0.0-alpha.12](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.11...doc@1.0.0-alpha.12) (2026-03-23)

* refactor!: streamline component function naming to unified two-function pattern ([06814fd](https://github.com/ReventlessDev/reventless-core/commit/06814fd8589cf05ce8a9f9654552e7d5cd9c6bf2))

### BREAKING CHANGES

* All component function signatures changed. Behavior.decide
now returns result<array<event>, error> instead of using errorHandler callback.
StateChangeSlice type decisionModel renamed to state. Projection.Mapping.map
renamed to project. StateViewSlice.project takes one argument instead of two.
# [1.0.0-alpha.11](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.10...doc@1.0.0-alpha.11) (2026-03-16)

* feat!: replace Core component with Platform_Admin, rename schema prefix Core_ → Admin_ ([940263d](https://github.com/ReventlessDev/reventless-core/commit/940263d8b39e28f4c874af3b0335ae81444928c4))
### Features

* internalize scheduler, Core, and setup in Platform.makePlatform ([ce3e1b6](https://github.com/ReventlessDev/reventless-core/commit/ce3e1b60e8ffdbab1a6b5cd08d73f5e907726481))

### BREAKING CHANGES

* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.
# [1.0.0-alpha.10](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.9...doc@1.0.0-alpha.10) (2026-03-14)

### Features

* implement hybrid API/MCP schema split (core vs plugins) ([4f84866](https://github.com/ReventlessDev/reventless-core/commit/4f848667c0814533b2f3a294350c4310c61d9fc7))
# [1.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.8...doc@1.0.0-alpha.9) (2026-03-08)

### Features

* replace explicit queryMode with automatic schema-driven DCB query construction ([8df4350](https://github.com/ReventlessDev/reventless-core/commit/8df4350c37f1f15678f4796f229647eaeb3e8222))
# [1.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.7...doc@1.0.0-alpha.8) (2026-03-08)

### Bug Fixes

* **deps:** add missing mermaid architecture diagram dependencies ([25cbd74](https://github.com/ReventlessDev/reventless-core/commit/25cbd74abd0ac758a0bd4cfa8d9692acc22084ed))
### Features

* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* auto-generate GraphQL mutations for InboundTranslationSlice ([7011fd2](https://github.com/ReventlessDev/reventless-core/commit/7011fd29f3029f001aa94fa78eb4f6b34d45451e))
* **examples:** add AutomationSlice, InboundTranslationSlice, and OutboundTranslationSlice to DCB online shop ([6e2da0a](https://github.com/ReventlessDev/reventless-core/commit/6e2da0a2629085750bdd707feb961e4e65c2c70c))
* **examples:** add EventMapper, SideEffectHandler, and Task to aggregates online shop ([b8c3237](https://github.com/ReventlessDev/reventless-core/commit/b8c3237f4608f5b85d175ede89d8a335d10afbeb))
* restructure DCB example into online-shop-dcb with spec packages ([0ee5a10](https://github.com/ReventlessDev/reventless-core/commit/0ee5a10c55248c8e27087f69cdce61a24f98027f))
# [1.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.6...doc@1.0.0-alpha.7) (2026-03-02)

**Note:** Version bump only for package doc

# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.5...doc@1.0.0-alpha.6) (2026-03-01)

### Bug Fixes

* **doc:** align Docusaurus packages to 3.9.2 and fix React version mismatch ([6a2d660](https://github.com/ReventlessDev/reventless-core/commit/6a2d6604e6bf45935fb8be9d09fe9bc5e9410070))
* **docs:** resolve Mermaid ColorModeProvider error and add remark-d2 support ([2f948e5](https://github.com/ReventlessDev/reventless-core/commit/2f948e5d3ad778c19da0064b563d0e026da30aa1))
* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))
### Features

* **doc:** add Online Shop Example docs site with Catalog and Ordering contexts ([b4a99d4](https://github.com/ReventlessDev/reventless-core/commit/b4a99d4285a7b1b1d6f0e522c959af2069fdc564))
* **reventless-interop:** implement versioned cross-plugin contract package ([24ce205](https://github.com/ReventlessDev/reventless-core/commit/24ce205e5b7e0780069fec6bf696170f90cd648c))
* **reventless-spec:** migrate platform types to spec package ([d9d39d9](https://github.com/ReventlessDev/reventless-core/commit/d9d39d9287557633f3f0c1cd03344f09a446f99b))
* **test:** add unified root-level test runner with compact reporter ([71fee3d](https://github.com/ReventlessDev/reventless-core/commit/71fee3d4563f07e2fe6a5985f68dff990bef61d2))

### BREAKING CHANGES

* ReventlessSpec namespace renamed to Reventless; the reventless-core
package namespace renamed from Reventless to ReventlessCore.
All usages of ReventlessSpec.* must be updated to Reventless.*;
all usages of Reventless.* (core) in dependent packages must be updated to ReventlessCore.*
# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.4...doc@1.0.0-alpha.5) (2026-02-18)

### Features

* implement StateViewSlice component ([d9a9a99](https://github.com/ReventlessDev/reventless-core/commit/d9a9a996729405d0e282502571b4e8a148e9980c))
# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.3...doc@1.0.0-alpha.4) (2026-02-18)

**Note:** Version bump only for package doc

# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/doc@1.0.0-alpha.2...doc@1.0.0-alpha.3) (2026-02-13)

### Bug Fixes

* **doc:** resolve broken anchor links in documentation ([e02529d](https://github.com/ReventlessDev/reventless-core/commit/e02529d63fb1402cab455f87aa2c20c4668cd55a))
### Features

* **doc:** add local search functionality to documentation ([6f33cd2](https://github.com/ReventlessDev/reventless-core/commit/6f33cd21029fd67efac2795ffc5034efa3c0c2c7))
# 1.0.0-alpha.2 (2026-02-12)
### Bug Fixes

* exclude private packages from versioning and automate doc CHANGELOG updates ([7581d78](https://github.com/ReventlessDev/reventless-core/commit/7581d78e9825fa6d837da8a136b361dee821660f))
* Update sury GitHub repository URLs (qa-requested) ([57a8bd8](https://github.com/ReventlessDev/reventless-core/commit/57a8bd86862c579e1dbc055f668389c186fc2c03))
### Code Refactoring

* rename Behaviour to Behavior (British to American spelling) ([6575f44](https://github.com/ReventlessDev/reventless-core/commit/6575f4415fa0fb27472f3520038f158dd624da03))
### Features

* add GitHub Pages deployment with multi-version documentation ([3e9ccfd](https://github.com/ReventlessDev/reventless-core/commit/3e9ccfd4726ed99c518cbfa42c35aeb71e4eb53d))
### BREAKING CHANGES

* All references to Behaviour module must be updated to Behavior

# Documentation Changes

This file tracks changes to the documentation. Since the doc package is not versioned or released, changes are listed sequentially without version sections.

**Note:** This CHANGELOG is automatically updated by CI when changes are pushed to main, beta, or alpha branches. The CI extracts commits affecting `packages/doc/**` and adds them here with commit links.

## Changes

### 2026-02-12
- feat: add GitHub Pages deployment with multi-version documentation ([3e9ccfd](https://github.com/ReventlessDev/reventless-core/commit/3e9ccfd4726ed99c518cbfa42c35aeb71e4eb53d))
- **Breaking Change**: rename Behaviour to Behavior (British to American spelling) - all references to Behaviour module must be updated to Behavior ([6575f44](https://github.com/ReventlessDev/reventless-core/commit/6575f4415fa0fb27472f3520038f158dd624da03))
- fix: update sury GitHub repository URLs (qa-requested) ([57a8bd8](https://github.com/ReventlessDev/reventless-core/commit/57a8bd86862c579e1dbc055f668389c186fc2c03))
