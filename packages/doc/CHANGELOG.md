# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

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
