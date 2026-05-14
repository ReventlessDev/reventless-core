# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

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
