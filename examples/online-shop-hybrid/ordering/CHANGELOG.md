# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.48 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.47 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.46 (2026-05-18)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.45 (2026-05-18)

### Features

* **plugin:** wire end-to-end user-extension dispatch through plugin EventCollectors ([f616abe](https://github.com/ReventlessDev/reventless-core/commit/f616abe169289f836f8e538b5419cb82cda886d7))


# 1.0.0-alpha.44 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.43 (2026-05-17)

### Bug Fixes

* **deps:** pin sury-ppx to 11.0.0-alpha.2 to prevent prerelease drift ([c9d05fe](https://github.com/ReventlessDev/reventless-core/commit/c9d05fe5118a9c0442ca3e071f2606b3a139fc81))


# 1.0.0-alpha.42 (2026-05-17)

### Bug Fixes

* **aws:** wire schedulerRoleArn through admin registers; default heartbeat to 5 min ([f9580a2](https://github.com/ReventlessDev/reventless-core/commit/f9580a2fc7f85a67747ccaab87358f303bd90ab9))


# 1.0.0-alpha.41 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.40 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.39 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.38 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.37 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.36 (2026-05-16)

### Bug Fixes

* **example:** hide hybrid AvailableProducts StateViewSlice from AutoUI ([a7a5d4f](https://github.com/ReventlessDev/reventless-core/commit/a7a5d4f0d823342dc26cf588f063cd662f20246a))
### Features

* **ppx:** add @[@reventless](https://github.com/reventless).visibility to hide components from AutoUI ([bd302cf](https://github.com/ReventlessDev/reventless-core/commit/bd302cfc5bd5d4dfe50c8e1bf8596ab67e36c74e))


# 1.0.0-alpha.35 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.34 (2026-05-16)

### Features

* **examples:** annotate Order [@allowed](https://github.com/allowed)States + [@status](https://github.com/status) across online-shop examples ([b63a6c1](https://github.com/ReventlessDev/reventless-core/commit/b63a6c184e74443df21cb5abdefdafca5a143668))


# 1.0.0-alpha.33 (2026-05-14)

### Features

* **ppx:** inline-spec walk + Spec module types require authorization ([7db9ec0](https://github.com/ReventlessDev/reventless-core/commit/7db9ec0f186578ce0088973dba22da9257be6a61))


# 1.0.0-alpha.32 (2026-05-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.31 (2026-05-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.30 (2026-05-05)

### Features

* **dcb:** allow plural *Ids field names with shared singular tag key ([19a5167](https://github.com/ReventlessDev/reventless-core/commit/19a5167ed904c6152c137af738f869ee4d26287e))
* **extension:** add PublishStateChangeSliceCommand for slice delegates ([0500b79](https://github.com/ReventlessDev/reventless-core/commit/0500b79d80632611e52ff0565e3e04472330a51e))


# 1.0.0-alpha.29 (2026-05-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.28 (2026-05-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.27 (2026-05-03)

### Bug Fixes

* **examples:** Orders EP Delegate.name must match DCB log convention ([1f6c094](https://github.com/ReventlessDev/reventless-core/commit/1f6c09494bf295ae4743cdedc01c16f97e9ff8d6))


# 1.0.0-alpha.26 (2026-05-03)

### Bug Fixes

* **examples:** hybrid PlaceOrder must discriminate OrderPlaced by orderId ([ad25e17](https://github.com/ReventlessDev/reventless-core/commit/ad25e17f94c7217f5cb0fa713b85121eb43bfc11))
* three follow-ups from the GWT-coverage migration ([3be14a4](https://github.com/ReventlessDev/reventless-core/commit/3be14a4cab276a989ae4a93aa650a6086ec118cf))
* feat(ppx)!: add @@reventless.mappings/extension/task; collapse AutomationSlice.Make to 2 args ([c0268ac](https://github.com/ReventlessDev/reventless-core/commit/c0268ac42c1c887fe25467af61b412ab2e27a5a7))
### Features

* **ppx,examples:** full GWT coverage for example plugins ([9331744](https://github.com/ReventlessDev/reventless-core/commit/9331744d232802d996f3897d7eca6e8c6b735f68))

### BREAKING CHANGES

* Platform.AutomationSlice.Make is now 2-arg (Spec, Automation).
External callers must either rerun generate-plugin or merge their _Mappings
contents into _Automation (or add the same two-line bridge).

Verified: zero warnings, 1174/1175 tests pass — the single failing test
(OrderingE2ETest "after syncing missing product, PlaceOrder succeeds") was
confirmed pre-existing on alpha (the known testPromise concurrency race).



# 1.0.0-alpha.25 (2026-04-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.24 (2026-04-27)

### Bug Fixes

* **spec:** regenerate plugins; simplify codegen, drop Maker suffix ([8d81302](https://github.com/ReventlessDev/reventless-core/commit/8d81302a9dc3403f98298ff69b19901d625dff7e))


# 1.0.0-alpha.23 (2026-04-26)

* refactor(automation)!: drop tagSet and toTags from Mapping API ([c9cd7f2](https://github.com/ReventlessDev/reventless-core/commit/c9cd7f2a1c1758990cb3d83a6876348477fe89d6))
* feat!: mixed-source AutomationSlice — Plan 04 ([fae3fbf](https://github.com/ReventlessDev/reventless-core/commit/fae3fbf93b12ecf62d0883fe7335ed73c6f52d67))

### BREAKING CHANGES

* Mapping/MappingImpl no longer have `type tagSet`
or `let toTags`. Mappings declared in user code with `type tagSet`
or `let toTags` need those lines removed. Migrate any toTags
validation logic to `collect` (filter) or to `@s.matches` /
`@compositePartitionTag` annotations on the command schema.
* AutomationSlice.Spec drops consumedEvent;
AutomationSlice_Builder.Make takes Mappings as 3rd arg; make signature
swaps ~dcbEventLog for ~allEventTopics + ~context; Plugin_Builder.Spec
gains platformName. Existing slices need a sibling _Mappings.res file
and updated Plugin.res (regenerate via prebuild hook).

Tests: 362/362 pass. Build clean, zero warnings.

Plan: docs/plans/done/mixed-source-automationslice.md
Guide: docs/guides/mixed-source-automationslice.md



# 1.0.0-alpha.22 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.21 (2026-04-24)

### Features

* **gwt:** add 5 DCB slice DSLs and thread slice name into hints (Stage 3) ([62b59fd](https://github.com/ReventlessDev/reventless-core/commit/62b59fdaa745d7799209ec3c24c50a8d443670b5))
* **gwt:** add Stage 4 AppendConditionMismatch + Stage 5 Mapping_GWT ([24fa835](https://github.com/ReventlessDev/reventless-core/commit/24fa8353657329e73a04cfed8e0a390806ff3395))
* **gwt:** extract GWT test DSLs into @reventlessdev/reventless-gwt package ([dd64b4e](https://github.com/ReventlessDev/reventless-core/commit/dd64b4e1fd0bb203821d055b6743a52aec1836fb))


# 1.0.0-alpha.20 (2026-04-22)

### Features

* add composite [@display](https://github.com/display)Name annotation with projected displayName column ([115f550](https://github.com/ReventlessDev/reventless-core/commit/115f5506231f635e261d977da0ca32bdabef817f))
* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))
* **spec:** wire UI fragment manifest through plugin make via ~uiBundleUrl ([e07fa3a](https://github.com/ReventlessDev/reventless-core/commit/e07fa3a05d6effdd4c6c6686ab1f7e4e4312c438))


# 1.0.0-alpha.19 (2026-04-20)

### Features

* add automationSlices, translation slices, and extensions to pluginStructure ([631e2f3](https://github.com/ReventlessDev/reventless-core/commit/631e2f3636f0a422e58712f70106c0df8effc1e9))


# 1.0.0-alpha.18 (2026-04-18)

### Features

* **core:** AutoUI definition — makeAutoUIDefinition, Platform_UIDefinitions query, generator support ([513ca53](https://github.com/ReventlessDev/reventless-core/commit/513ca5399b0b6e5ae6a982fd15693de2ea208b8d))
* **core:** uiFragments manifest — Phase 1 implementation with generic types ([1e73f62](https://github.com/ReventlessDev/reventless-core/commit/1e73f623984118081d2b985c48521812e4f8417e))


# 1.0.0-alpha.17 (2026-04-15)

### Features

* zero-touch plugin assembly — generate Plugin.res from folder structure ([73ea654](https://github.com/ReventlessDev/reventless-core/commit/73ea654ab9a73f15ea7e18631e8194bfe0f4580f))


# 1.0.0-alpha.16 (2026-04-09)

### Features

* **ppx:** implement [@no](https://github.com/no)Api to exclude commands from GraphQL/MCP exposure ([079b686](https://github.com/ReventlessDev/reventless-core/commit/079b68693976a53f8094f1233ebf8b67a86a65c0))


# 1.0.0-alpha.15 (2026-04-07)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.14 (2026-04-07)

### Features

* **ppx+querydb:** annotation-driven key design and sort key queries ([dee6de8](https://github.com/ReventlessDev/reventless-core/commit/dee6de84c2d2de5431d064f18ac7132bc8c23110))


# 1.0.0-alpha.13 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))
* **ppx:** preserve full entity name for files in slice folders ([5471b3f](https://github.com/ReventlessDev/reventless-core/commit/5471b3f2a64e5dbc85441ae22bfa53c194f84689))
* **ppx:** update compiled output for View suffix stripping in StateViewSlice ([857cb89](https://github.com/ReventlessDev/reventless-core/commit/857cb896fcb30d4a52585276dabbbcf80b3403a4))


# 1.0.0-alpha.12 (2026-04-06)

### Bug Fixes

* **examples:** suppress [@no](https://github.com/no)Tag on customerId in PlaceOrder command to prevent cross-order DCB query contamination ([f9d674e](https://github.com/ReventlessDev/reventless-core/commit/f9d674eb425989b2b49231ec0fedc9833e76485b))
### Features

* implement [@composite](https://github.com/composite)PartitionTag PPX annotation for multi-field DCB partition keys ([cf26b15](https://github.com/ReventlessDev/reventless-core/commit/cf26b15f639d151451c9aa04d32603ef9d5df315))


# 1.0.0-alpha.11 (2026-04-05)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# 1.0.0-alpha.10 (2026-04-04)

### Bug Fixes

* DCB [@partition](https://github.com/partition)Tag runtime errors, GraphQL Node interface, and ESM config ([dc4c4e1](https://github.com/ReventlessDev/reventless-core/commit/dc4c4e10f1ef09aba840e7b359df453b122c6aa4))
### Features

* migrate online-shop-hybrid example to reventless-ppx ([ac66980](https://github.com/ReventlessDev/reventless-core/commit/ac669807bf94b061b85e0217f1ec76af50d12a44))


# 1.0.0-alpha.9 (2026-03-30)

### Features

* **examples:** publish example packages to GitHub Package Registry ([2495ba5](https://github.com/ReventlessDev/reventless-core/commit/2495ba5c4436613d58964f9948c1bacbde61965f))


# [1.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.6...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.8) (2026-03-28)

### Bug Fixes

* **examples:** regenerate stale .mjs for aggregate, dcb, and hybrid plugins ([b5b4de5](https://github.com/ReventlessDev/reventless-core/commit/b5b4de5c4db7f5f8eb9071157302c4f0796b1889))
* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))

### BREAKING CHANGES

* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [1.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.6...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.7) (2026-03-27)

* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))

### BREAKING CHANGES

* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.3...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.6) (2026-03-27)

* feat!: remove resolverConfig from Behavior module type ([6f54015](https://github.com/ReventlessDev/reventless-core/commit/6f54015e3abc1c5c05472c8f54645723a0f5ed28))
* feat!: decouple DCB slices from shared event log union type ([2a40e8d](https://github.com/ReventlessDev/reventless-core/commit/2a40e8dd9babfb88440fcaccde6fb667b60e0ba9))

### BREAKING CHANGES

* Behavior.T no longer requires resolverConfig. Remove it
from all Behavior implementations.
* All DCB slice specs must use `producedEvent`/`consumedEvent`
instead of `module DcbEventLogSpec`. Plugin `DcbSpec` no longer has `type event`
or `with type dcbEvent` constraints.



# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.3...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.5) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.3...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.4) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.2...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.3) (2026-03-23)

* refactor!: streamline component function naming to unified two-function pattern ([06814fd](https://github.com/ReventlessDev/reventless-core/commit/06814fd8589cf05ce8a9f9654552e7d5cd9c6bf2))
* fix(reventless-aws)!: resolve DcbEventLogSpec undefined at runtime and add AppSync routing ([85138a3](https://github.com/ReventlessDev/reventless-core/commit/85138a39afe97047ea5f063508994e20544eb780))

### BREAKING CHANGES

* All component function signatures changed. Behavior.decide
now returns result<array<event>, error> instead of using errorHandler callback.
StateChangeSlice type decisionModel renamed to state. Projection.Mapping.map
renamed to project. StateViewSlice.project takes one argument instead of two.

* DcbEventLog.Spec now requires `let moduleUrl: string` field.
Add `let moduleUrl: string = %raw(\`import.meta.url\`)` to event log modules.
# [1.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.1...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.2) (2026-03-22)

* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [1.0.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.0...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.1) (2026-03-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering

# [1.0.0-alpha.0](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@0.1.0-alpha.1...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.0) (2026-03-16)

* feat!: auto-detect plugin version from package.json via V8 stack trace ([e172673](https://github.com/ReventlessDev/reventless-core/commit/e17267390c197fa34052cef8325c579bb781419f))

### BREAKING CHANGES

* Plugin.make no longer accepts ~version.
# [0.1.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@0.1.0-alpha.0...@reventlessdev/online-shop-hybrid-ordering@0.1.0-alpha.1) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# 0.1.0-alpha.0 (2026-03-08)

### Features

* **examples:** add online-shop-hybrid example with aggregate + DCB composition ([296ad05](https://github.com/ReventlessDev/reventless-core/commit/296ad05f067c53854d4cf0a5d4a8deb91d751b04))
* replace explicit queryMode with automatic schema-driven DCB query construction ([8df4350](https://github.com/ReventlessDev/reventless-core/commit/8df4350c37f1f15678f4796f229647eaeb3e8222))
