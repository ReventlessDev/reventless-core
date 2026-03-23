# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.2...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.3) (2026-03-23)

* refactor!: streamline component function naming to unified two-function pattern ([06814fd](https://github.com/ReventlessDev/reventless-core/commit/06814fd8589cf05ce8a9f9654552e7d5cd9c6bf2))
* fix(reventless-aws)!: resolve DcbEventLogSpec undefined at runtime and add AppSync routing ([85138a3](https://github.com/ReventlessDev/reventless-core/commit/85138a39afe97047ea5f063508994e20544eb780))

### BREAKING CHANGES

* All component function signatures changed. Behavior.decide
now returns result<array<event>, error> instead of using errorHandler callback.
StateChangeSlice type decisionModel renamed to state. Projection.Mapping.map
renamed to project. StateViewSlice.project takes one argument instead of two.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
* DcbEventLog.Spec now requires `let moduleUrl: string` field.
Add `let moduleUrl: string = %raw(\`import.meta.url\`)` to event log modules.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>



# [1.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.1...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.2) (2026-03-22)

* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>



# [1.0.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.0...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.1) (2026-03-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-ordering





# [1.0.0-alpha.0](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@0.1.0-alpha.1...@reventlessdev/online-shop-hybrid-ordering@1.0.0-alpha.0) (2026-03-16)

* feat!: auto-detect plugin version from package.json via V8 stack trace ([e172673](https://github.com/ReventlessDev/reventless-core/commit/e17267390c197fa34052cef8325c579bb781419f))

### BREAKING CHANGES

* Plugin.make no longer accepts ~version.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>



# [0.1.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-ordering@0.1.0-alpha.0...@reventlessdev/online-shop-hybrid-ordering@0.1.0-alpha.1) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))


# 0.1.0-alpha.0 (2026-03-08)

### Features

* **examples:** add online-shop-hybrid example with aggregate + DCB composition ([296ad05](https://github.com/ReventlessDev/reventless-core/commit/296ad05f067c53854d4cf0a5d4a8deb91d751b04))
* replace explicit queryMode with automatic schema-driven DCB query construction ([8df4350](https://github.com/ReventlessDev/reventless-core/commit/8df4350c37f1f15678f4796f229647eaeb3e8222))
